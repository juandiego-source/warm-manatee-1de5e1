-- Sumak Ops — let an invoice include its job's completion photos
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Safe to run again.
--
-- Adds one column to invoices. It does not update, delete, or backfill
-- any other data. Existing rows default to true (include photos).
--
-- The office app shows those photos on the invoice and, when the box
-- stays checked, puts signed photo links in the client email. The links
-- open only those image files. This does not make the job-photos bucket
-- public, and it does not give clients or subs any other invoice fields.
--
-- No new policies. Admins already own invoices. Subs do not have invoices.

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS include_job_photos boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.invoices.include_job_photos IS
  'When true, completion photos from the linked job are shown on the office invoice and sent to the client as signed image links. Defaults on.';

SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'invoices'
  AND column_name = 'include_job_photos';
