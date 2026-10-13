-- Sumak Ops — record lump-sum and partial payouts to subs
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this whole file into the SQL editor and run it once.
-- Safe to run again.
--
-- Nothing here emails, texts, or notifies a client or a sub.
-- Mark as Paid on a job is unchanged. This is an extra record of money
-- you actually handed a sub, which can cover several jobs or only part of one.
-- Only an admin can read or write these tables. Subs keep using sub_jobs
-- and never see client prices here.
--
-- No new functions. Policies call the existing is_admin().

-- =============================================================================
-- BLOCK 1 — Tables
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.sub_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subcontractor_id uuid NOT NULL REFERENCES public.subcontractors(id),
  paid_on date NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  method text,
  reference text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE TABLE IF NOT EXISTS public.sub_payment_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sub_payment_id uuid NOT NULL REFERENCES public.sub_payments(id) ON DELETE CASCADE,
  job_id uuid NOT NULL REFERENCES public.jobs(id),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  UNIQUE (sub_payment_id, job_id)
);

CREATE INDEX IF NOT EXISTS sub_payments_sub_paid_on_idx
  ON public.sub_payments (subcontractor_id, paid_on);

CREATE INDEX IF NOT EXISTS sub_payment_jobs_job_idx
  ON public.sub_payment_jobs (job_id);

COMMENT ON TABLE public.sub_payments IS
  'Money paid to a sub. Admin reports only. Does not replace job Mark as Paid.';
COMMENT ON TABLE public.sub_payment_jobs IS
  'How much of a payout applies to one job. Partial amounts are allowed.';

-- =============================================================================
-- BLOCK 2 — Admin-only access
-- =============================================================================

REVOKE ALL ON TABLE public.sub_payments FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.sub_payment_jobs FROM PUBLIC, anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.sub_payments TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.sub_payment_jobs TO authenticated;

ALTER TABLE public.sub_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_payment_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sub_payments_admin_all ON public.sub_payments;
DROP POLICY IF EXISTS sub_payment_jobs_admin_all ON public.sub_payment_jobs;

CREATE POLICY sub_payments_admin_all
  ON public.sub_payments
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY sub_payment_jobs_admin_all
  ON public.sub_payment_jobs
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- Check: both tables exist, row security is on, and only an admin policy is attached.
SELECT c.relname, c.relrowsecurity AS row_security
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('sub_payments', 'sub_payment_jobs')
ORDER BY c.relname;

SELECT tablename, policyname, roles, cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('sub_payments', 'sub_payment_jobs')
ORDER BY tablename, policyname;
