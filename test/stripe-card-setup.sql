-- Local fixture only. Do not run this against the Sumak Ops project.
-- Builds the invoice and notification tables the card-payment script alters.

CREATE SCHEMA IF NOT EXISTS auth;

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

CREATE TABLE IF NOT EXISTS public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now(),
  invoice_number text UNIQUE,
  status text DEFAULT 'Unpaid',
  subtotal numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  total numeric DEFAULT 0,
  paid_at timestamptz,
  payment_method text,
  payment_reference text,
  paid_on date,
  notes text,
  CONSTRAINT invoices_status_check CHECK (status = ANY (ARRAY['Unpaid'::text, 'Paid'::text, 'Overdue'::text]))
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now(),
  recipient_role text NOT NULL,
  recipient_sub_id uuid,
  message text NOT NULL,
  link_type text,
  link_id uuid,
  read boolean DEFAULT false
);
