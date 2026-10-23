-- Local fixture only. Do not run this against the Sumak Ops project.
-- It builds a throwaway database, then sql/2026-10-23-sub-access.sql is applied,
-- then test/sub-access-assert.sql signs in as a sub and tries the office tables.

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END
$roles$;

GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;
GRANT USAGE ON SCHEMA auth TO postgres, authenticated, service_role;
GRANT USAGE ON SCHEMA storage TO postgres, authenticated, anon, service_role;

CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  raw_user_meta_data jsonb
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  claims text;
  sub text;
BEGIN
  sub := nullif(current_setting('request.jwt.claim.sub', true), '');
  IF sub IS NOT NULL THEN
    RETURN sub::uuid;
  END IF;
  claims := nullif(current_setting('request.jwt.claims', true), '');
  IF claims IS NULL OR btrim(claims) = '' THEN
    RETURN NULL;
  END IF;
  BEGIN
    RETURN nullif(claims::json->>'sub', '')::uuid;
  EXCEPTION WHEN others THEN
    RETURN NULL;
  END;
END;
$fn$;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id text PRIMARY KEY,
  name text,
  public boolean
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text,
  name text,
  owner uuid
);

INSERT INTO storage.buckets (id, name, public)
VALUES ('job-photos', 'job-photos', true)
ON CONFLICT (id) DO UPDATE SET public = true, name = EXCLUDED.name;

GRANT SELECT ON storage.buckets TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated, anon;

-- Hosted Supabase already enables this. The production script must not,
-- because the SQL editor cannot ALTER storage.objects. This local table
-- is owned by postgres, so the test turns the lock on here.
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY,
  email text,
  role text,
  subcontractor_id uuid,
  full_name text
);

CREATE TABLE IF NOT EXISTS public.subcontractors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text,
  phone text,
  email text,
  specialty text,
  active boolean DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text,
  email text,
  phone text,
  deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.properties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid,
  address text
);

CREATE TABLE IF NOT EXISTS public.jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_number text,
  title text,
  description text,
  address text,
  scheduled_date date,
  status text,
  completed_at timestamptz,
  accepted_at timestamptz,
  notes text,
  site_report jsonb,
  subcontractor_id uuid,
  customer_id uuid,
  estimate_id uuid,
  recurring_service_id uuid,
  sub_pay numeric(12,2),
  client_price numeric(12,2),
  payment_status text,
  payment_method text,
  paid_at date,
  created_at timestamptz DEFAULT now(),
  deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.estimates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid,
  estimate_number text,
  total numeric(12,2),
  public_token text
);

CREATE TABLE IF NOT EXISTS public.estimate_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  estimate_id uuid,
  unit_price numeric(12,2),
  total numeric(12,2),
  cost numeric(12,2),
  margin_pct numeric(8,2)
);

CREATE TABLE IF NOT EXISTS public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid,
  invoice_number text,
  total numeric(12,2),
  status text
);

CREATE TABLE IF NOT EXISTS public.invoice_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid,
  job_id uuid,
  unit_price numeric(12,2),
  total numeric(12,2),
  cost numeric(12,2),
  margin_pct numeric(8,2),
  quantity numeric
);

CREATE TABLE IF NOT EXISTS public.recurring_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid,
  title text,
  client_price numeric(12,2),
  sub_pay numeric(12,2)
);

CREATE TABLE IF NOT EXISTS public.services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text,
  default_price numeric(12,2),
  active boolean
);

CREATE TABLE IF NOT EXISTS public.sub_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subcontractor_id uuid,
  paid_on date,
  amount numeric(12,2),
  method text,
  reference text,
  notes text,
  created_at timestamptz DEFAULT now(),
  created_by uuid
);

CREATE TABLE IF NOT EXISTS public.sub_payment_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sub_payment_id uuid,
  job_id uuid,
  amount numeric(12,2)
);

CREATE TABLE IF NOT EXISTS public.cost_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid,
  subcontractor_id uuid,
  title text,
  description text,
  address text,
  status text,
  submitted_cost numeric(12,2),
  submitted_notes text,
  submitted_at timestamptz,
  created_at timestamptz DEFAULT now(),
  office_price numeric(12,2)
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_role text,
  recipient_sub_id uuid,
  message text,
  link_type text,
  link_id uuid,
  read boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_role text,
  actor_name text,
  action text,
  detail text,
  entity_type text,
  entity_id uuid,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  recipient_role text,
  recipient_sub_id uuid,
  endpoint text,
  p256dh text,
  auth_key text
);

CREATE TABLE IF NOT EXISTS public.job_photos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid,
  url text,
  created_at timestamptz DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role = 'admin'
  );
$fn$;

GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, anon, service_role;

-- Fixed ids so the assert file can name them.
INSERT INTO public.subcontractors (id, name, email) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Sub A', 'a@example.com'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Sub B', 'b@example.com'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Sub C', 'c@example.com')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.customers (id, name, email, phone) VALUES
  ('d0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0', 'Private Client', 'secret@customer.test', '208-555-0100')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.jobs (
  id, job_number, title, status, subcontractor_id, customer_id,
  sub_pay, client_price, payment_status, address, scheduled_date
) VALUES
  (
    '11111111-1111-4111-8111-111111111111', 'SMK-A', 'Own visit', 'Pending',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'd0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0',
    40.00, 125.00, 'Unpaid', '1 Own St', DATE '2026-10-23'
  ),
  (
    '22222222-2222-4222-8222-222222222222', 'SMK-B', 'Other visit', 'Pending',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'd0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0',
    77.00, 400.00, 'Unpaid', '2 Other St', DATE '2026-10-01'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, email, role, subcontractor_id) VALUES
  ('aaaa1111-1111-4111-8111-111111111111', 'admin@example.com', 'admin', NULL),
  ('aaaa2222-2222-4222-8222-222222222222', 'suba@example.com', 'sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('aaaa3333-3333-4333-8333-333333333333', 'subb@example.com', 'sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, raw_user_meta_data) VALUES
  ('aaaa1111-1111-4111-8111-111111111111', '{}'::jsonb),
  ('aaaa2222-2222-4222-8222-222222222222', '{}'::jsonb),
  ('aaaa3333-3333-4333-8333-333333333333', '{}'::jsonb),
  ('aaaa4444-4444-4444-8444-444444444444', jsonb_build_object('invited_sub_id', 'cccccccc-cccc-cccc-cccc-cccccccccccc')),
  ('aaaa5555-5555-4555-8555-555555555555', jsonb_build_object('invited_sub_id', 'not-a-uuid')),
  ('aaaa6666-6666-4666-8666-666666666666', jsonb_build_object('invited_sub_id', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')),
  ('aaaa7777-7777-4777-8777-777777777777', '{}'::jsonb)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.invoices (id, customer_id, invoice_number, total, status) VALUES
  ('e1e1e1e1-e1e1-41e1-81e1-e1e1e1e1e1e1', 'd0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0', 'INV-9', 400.00, 'Unpaid')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.invoice_items (id, invoice_id, job_id, unit_price, total, cost, margin_pct, quantity) VALUES
  ('e2e2e2e2-e2e2-42e2-82e2-e2e2e2e2e2e2', 'e1e1e1e1-e1e1-41e1-81e1-e1e1e1e1e1e1', '22222222-2222-4222-8222-222222222222', 400.00, 400.00, 77.00, 80.75, 1)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.estimates (id, customer_id, estimate_number, total) VALUES
  ('e3e3e3e3-e3e3-43e3-83e3-e3e3e3e3e3e3', 'd0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0', 'EST-9', 500.00)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.estimate_items (id, estimate_id, unit_price, total, cost, margin_pct) VALUES
  ('e4e4e4e4-e4e4-44e4-84e4-e4e4e4e4e4e4', 'e3e3e3e3-e3e3-43e3-83e3-e3e3e3e3e3e3', 500.00, 500.00, 90.00, 82.00)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.sub_payments (id, subcontractor_id, paid_on, amount, method, notes) VALUES
  ('e5e5e5e5-e5e5-45e5-85e5-e5e5e5e5e5e5', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', DATE '2026-10-02', 77.00, 'Zelle', 'other sub payout')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.recurring_services (id, customer_id, title, client_price, sub_pay) VALUES
  ('e6e6e6e6-e6e6-46e6-86e6-e6e6e6e6e6e6', 'd0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0', 'Weekly', 90.00, 30.00)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.services (id, name, default_price, active) VALUES
  ('e7e7e7e7-e7e7-47e7-87e7-e7e7e7e7e7e7', 'Mow', 75.00, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cost_requests (
  id, customer_id, subcontractor_id, title, status, office_price, created_at
) VALUES
  (
    'e8e8e8e8-e8e8-48e8-88e8-e8e8e8e8e8e8',
    'd0d0d0d0-d0d0-d0d0-d0d0-d0d0d0d0d0d0',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'Quote for A', 'Requested', 999.00, now()
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.job_photos (id, job_id, url) VALUES
  ('e9e9e9e9-e9e9-49e9-89e9-e9e9e9e9e9e9', '11111111-1111-4111-8111-111111111111', 'https://example.test/job-photos/11111111-1111-4111-8111-111111111111/a.jpg'),
  ('eaeaeaea-eaea-4aea-8aea-eaeaeaeaeaea', '22222222-2222-4222-8222-222222222222', 'https://example.test/job-photos/22222222-2222-4222-8222-222222222222/b.jpg')
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.objects (id, bucket_id, name) VALUES
  ('f1f1f1f1-f1f1-41f1-81f1-f1f1f1f1f1f1', 'job-photos', '11111111-1111-4111-8111-111111111111/a.jpg'),
  ('f2f2f2f2-f2f2-42f2-82f2-f2f2f2f2f2f2', 'job-photos', '22222222-2222-4222-8222-222222222222/b.jpg')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.notifications (id, recipient_role, recipient_sub_id, message) VALUES
  ('f3f3f3f3-f3f3-43f3-83f3-f3f3f3f3f3f3', 'admin', NULL, 'Office only'),
  ('f4f4f4f4-f4f4-44f4-84f4-f4f4f4f4f4f4', 'sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Hello A'),
  ('f5f5f5f5-f5f5-45f5-85f5-f5f5f5f5f5f5', 'sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Hello B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.activity_log (id, actor_role, action, detail) VALUES
  ('f6f6f6f6-f6f6-46f6-86f6-f6f6f6f6f6f6', 'admin', 'Invoice created', 'client price 400')
ON CONFLICT (id) DO NOTHING;

-- Same column-order mismatch that failed in production (42P16): the
-- address position is still named customer_id. The migration must drop
-- these views before it creates the new ones. Nothing else depends on them.
CREATE VIEW public.sub_jobs AS
SELECT id, job_number, title, description, customer_id, address
FROM public.jobs;

CREATE VIEW public.sub_cost_requests AS
SELECT id, title, description, customer_id, address
FROM public.cost_requests;
