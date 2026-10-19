-- Sumak Ops — public estimate links (view and approve without an account)
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this WHOLE file into the Supabase SQL editor and run it once.
-- Safe to run again. It does not email, text, or notify anyone.
-- It does not grant anonymous read or write on estimates. A client can only
-- open the one estimate whose secret token is in the link, and only through
-- the three functions below.
--
-- After it succeeds, deploy the website (or merge the pull request) so the
-- email link points at /q/<token>. Old links that look like /?quote=<token>
-- keep working once the site is deployed.

-- =============================================================================
-- 1. Token column, backfill, and a trigger so every new estimate has a link
-- =============================================================================

ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS public_token text;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS client_response text;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS client_response_at timestamptz;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS client_note text;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS client_selected_items json;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS viewed_at timestamptz;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS view_count integer NOT NULL DEFAULT 0;

-- Only fills blanks. A link that was already emailed keeps its token.
UPDATE public.estimates
SET public_token = replace(gen_random_uuid()::text, '-', '')
WHERE public_token IS NULL OR btrim(public_token) = '';

DO $$
DECLARE
  dupes int;
BEGIN
  SELECT count(*) INTO dupes
  FROM (
    SELECT lower(btrim(public_token))
    FROM public.estimates
    WHERE public_token IS NOT NULL AND btrim(public_token) <> ''
    GROUP BY 1
    HAVING count(*) > 1
  ) d;
  IF dupes > 0 THEN
    RAISE EXCEPTION 'Two estimates share a public token. Stopped before replacing the approval functions. Fix the duplicate tokens, then run this file again.';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS estimates_public_token_uidx
  ON public.estimates (lower(btrim(public_token)));

CREATE OR REPLACE FUNCTION public.estimates_set_public_token()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  IF NEW.public_token IS NULL OR btrim(NEW.public_token) = '' THEN
    NEW.public_token := replace(gen_random_uuid()::text, '-', '');
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS estimates_set_public_token ON public.estimates;
CREATE TRIGGER estimates_set_public_token
  BEFORE INSERT ON public.estimates
  FOR EACH ROW
  EXECUTE FUNCTION public.estimates_set_public_token();

-- =============================================================================
-- 2. Replace the quote functions (any older argument list)
-- =============================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'get_public_quote',
        'mark_quote_viewed',
        'respond_to_quote',
        'quote_estimate_id',
        'quote_parse_selected'
      )
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig || ' CASCADE';
  END LOOP;
END $$;

-- Finds the one estimate for a token. Not granted to the public API.
-- A '+' in a token becomes a space in some email clients; try that form too.
CREATE FUNCTION public.quote_estimate_id(p_token text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT e.id
  FROM public.estimates e
  WHERE p_token IS NOT NULL
    AND btrim(p_token) <> ''
    AND (
      lower(btrim(e.public_token)) = lower(btrim(p_token))
      OR (
        position(' ' IN p_token) > 0
        AND lower(btrim(e.public_token)) = lower(btrim(replace(p_token, ' ', '+')))
      )
    )
  LIMIT 1;
$fn$;

CREATE FUNCTION public.quote_parse_selected(raw text)
RETURNS uuid[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $fn$
DECLARE
  j jsonb;
  el text;
  out uuid[] := ARRAY[]::uuid[];
BEGIN
  IF raw IS NULL OR btrim(raw) = '' OR lower(btrim(raw)) = 'null' THEN
    RETURN out;
  END IF;
  BEGIN
    j := btrim(raw)::jsonb;
  EXCEPTION WHEN others THEN
    RETURN out;
  END;
  IF jsonb_typeof(j) = 'string' THEN
    BEGIN
      j := (j #>> '{}')::jsonb;
    EXCEPTION WHEN others THEN
      RETURN out;
    END;
  END IF;
  IF jsonb_typeof(j) = 'string' THEN
    BEGIN
      j := (j #>> '{}')::jsonb;
    EXCEPTION WHEN others THEN
      RETURN out;
    END;
  END IF;
  IF jsonb_typeof(j) IS DISTINCT FROM 'array' THEN
    RETURN out;
  END IF;
  FOR el IN SELECT jsonb_array_elements_text(j)
  LOOP
    BEGIN
      out := array_append(out, el::uuid);
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END LOOP;
  RETURN out;
END;
$fn$;

CREATE FUNCTION public.get_public_quote(p_token text)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_est public.estimates%ROWTYPE;
  v_name text;
  v_items json;
BEGIN
  SELECT * INTO v_est
  FROM public.estimates
  WHERE id = public.quote_estimate_id(p_token);
  IF NOT FOUND THEN
    RETURN json_build_object('error', 'not_found');
  END IF;

  SELECT c.name INTO v_name
  FROM public.customers c
  WHERE c.id = v_est.customer_id;

  SELECT coalesce(
    json_agg(
      json_build_object(
        'id', i.id,
        'title', coalesce(nullif(btrim(i.title), ''), nullif(btrim(i.description), ''), 'Item'),
        'description', CASE
          WHEN i.title IS NOT NULL AND btrim(i.title) <> ''
           AND i.description IS NOT NULL AND btrim(i.description) <> ''
           AND btrim(i.description) IS DISTINCT FROM btrim(i.title)
          THEN i.description ELSE '' END,
        'quantity', i.quantity,
        'unit_price', i.unit_price,
        'total', i.total,
        'is_optional', coalesce(i.is_optional, false),
        'selected_by_default', coalesce(i.selected_by_default, false)
      )
      ORDER BY i.ctid
    ),
    '[]'::json
  )
  INTO v_items
  FROM public.estimate_items i
  WHERE i.estimate_id = v_est.id;

  RETURN json_build_object(
    'estimate_number', v_est.estimate_number,
    'client_name', coalesce(v_name, ''),
    'address', coalesce(v_est.address, ''),
    'notes', coalesce(v_est.notes, ''),
    'valid_until', v_est.valid_until,
    'tax_rate', coalesce(v_est.tax_rate, 0),
    'status', v_est.status,
    'client_response', nullif(btrim(coalesce(v_est.client_response, '')), ''),
    'client_selected_items', coalesce(v_est.client_selected_items, '[]'::json),
    'items', v_items
  );
END;
$fn$;

-- Opening the link records a view. It does not use up the token and it does
-- not approve or decline anything, so a mailbox that previews links is safe.
CREATE FUNCTION public.mark_quote_viewed(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  UPDATE public.estimates
  SET view_count = coalesce(view_count, 0) + 1,
      viewed_at = coalesce(viewed_at, now())
  WHERE id = public.quote_estimate_id(p_token);
END;
$fn$;

CREATE FUNCTION public.respond_to_quote(
  p_token text,
  p_response text,
  p_note text DEFAULT NULL,
  p_selected text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_est public.estimates%ROWTYPE;
  v_ids uuid[];
  v_note text;
  v_chosen json;
  v_sub numeric;
  v_tax numeric;
  v_total numeric;
  v_status text;
BEGIN
  IF p_response IS NULL OR p_response NOT IN ('Accepted', 'Declined', 'Changes Requested') THEN
    RETURN json_build_object('error', 'bad_response');
  END IF;

  SELECT * INTO v_est
  FROM public.estimates
  WHERE id = public.quote_estimate_id(p_token)
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('error', 'not_found');
  END IF;

  IF nullif(btrim(coalesce(v_est.client_response, '')), '') IS NOT NULL THEN
    IF v_est.client_response = p_response THEN
      RETURN json_build_object('ok', true, 'response', v_est.client_response, 'already', true);
    END IF;
    RETURN json_build_object('error', 'already_responded', 'response', v_est.client_response);
  END IF;

  v_note := nullif(left(btrim(coalesce(p_note, '')), 2000), '');
  v_ids := coalesce(public.quote_parse_selected(p_selected), ARRAY[]::uuid[]);

  SELECT coalesce(round(sum(i.total), 2), 0)
  INTO v_sub
  FROM public.estimate_items i
  WHERE i.estimate_id = v_est.id
    AND (
      NOT coalesce(i.is_optional, false)
      OR i.id = ANY (v_ids)
    );

  v_tax := round(v_sub * coalesce(v_est.tax_rate, 0) / 100, 2);
  v_total := v_sub + v_tax;

  SELECT coalesce(json_agg(s.id ORDER BY s.ctid), '[]'::json)
  INTO v_chosen
  FROM (
    SELECT i.id::text AS id, i.ctid
    FROM public.estimate_items i
    WHERE i.estimate_id = v_est.id
      AND (
        NOT coalesce(i.is_optional, false)
        OR i.id = ANY (v_ids)
      )
  ) s;

  UPDATE public.estimates
  SET status = CASE
        WHEN p_response = 'Accepted' THEN 'Approved'
        WHEN p_response = 'Declined' THEN 'Declined'
        ELSE status
      END,
      client_response = p_response,
      client_response_at = now(),
      client_note = v_note,
      client_selected_items = v_chosen,
      subtotal = CASE WHEN p_response = 'Accepted' THEN v_sub ELSE subtotal END,
      tax_amount = CASE WHEN p_response = 'Accepted' THEN v_tax ELSE tax_amount END,
      total = CASE WHEN p_response = 'Accepted' THEN v_total ELSE total END
  WHERE id = v_est.id;

  IF p_response = 'Accepted' THEN
    SELECT status INTO v_status FROM public.estimates WHERE id = v_est.id;
    IF v_status IS DISTINCT FROM 'Approved' THEN
      RAISE EXCEPTION 'status_blocked';
    END IF;
  ELSIF p_response = 'Declined' THEN
    SELECT status INTO v_status FROM public.estimates WHERE id = v_est.id;
    IF v_status IS DISTINCT FROM 'Declined' THEN
      RAISE EXCEPTION 'status_blocked';
    END IF;
  END IF;

  RETURN json_build_object(
    'ok', true,
    'response', p_response,
    'total', CASE WHEN p_response = 'Accepted' THEN v_total ELSE NULL END
  );
END;
$fn$;

-- Hidden helpers stay off the public API. The three quote functions are the
-- only ones an anonymous visitor can call, and each one requires the token.
REVOKE ALL ON FUNCTION public.quote_estimate_id(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quote_parse_selected(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_quote(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_quote_viewed(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_to_quote(text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_public_quote(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_quote_viewed(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_quote(text, text, text, text) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- 3. Checks (read only — the editor shows the last result)
-- =============================================================================

-- Expect three rows, all with prosecdef = true (they run with the owner's
-- rights, so row security on estimates does not hide the quote from a client).
SELECT p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_public_quote', 'mark_quote_viewed', 'respond_to_quote')
ORDER BY p.proname;

-- Expect one row. If a trigger rewrites status, approving from the link can
-- fail closed. This list is only a warning, not a change.
SELECT tgname
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'estimates'
  AND NOT t.tgisinternal
ORDER BY tgname;
