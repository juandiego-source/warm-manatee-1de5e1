-- Sumak Ops — record how a client paid an invoice
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Safe to run again.
--
-- Adds three empty columns to invoices. It does not update, delete, or
-- backfill any existing row. Older paid invoices stay paid with a blank
-- method, reference, and paid date until someone edits that payment.
--
-- payment_method   Check, Venmo, Zelle, Cash, ACH/bank deposit, Card, Other
-- payment_reference  optional check number, confirmation code, or note
-- paid_on           calendar date the client paid (the app still keeps paid_at)
--
-- No new functions or policies. Existing invoice permissions cover the new columns.

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS payment_reference text,
  ADD COLUMN IF NOT EXISTS paid_on date;

ALTER TABLE public.invoices
  DROP CONSTRAINT IF EXISTS invoices_payment_method_check;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_payment_method_check
  CHECK (
    payment_method IS NULL
    OR payment_method IN (
      'Check',
      'Venmo',
      'Zelle',
      'Cash',
      'ACH/bank deposit',
      'Card',
      'Other'
    )
  );

COMMENT ON COLUMN public.invoices.payment_method IS
  'How the client paid. Null on invoices paid before this column existed.';
COMMENT ON COLUMN public.invoices.payment_reference IS
  'Optional check number, confirmation code, or note.';
COMMENT ON COLUMN public.invoices.paid_on IS
  'Calendar date the client paid. Null when only the older paid_at timestamp is set.';

-- Check: the three columns exist and nothing was backfilled.
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'invoices'
  AND column_name IN ('payment_method', 'payment_reference', 'paid_on')
ORDER BY column_name;
