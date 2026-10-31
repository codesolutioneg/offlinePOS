-- AlterTable
ALTER TABLE "branches" ADD COLUMN "tax_connection_id" TEXT NOT NULL DEFAULT '';

-- Seed Balkans Nasr City Dishflow connection on matching branch names.
UPDATE "branches"
SET "tax_connection_id" = 'yFsBtvlradoAkKSascZ3'
WHERE "tax_connection_id" = ''
  AND (
    lower(name) LIKE '%nasr%'
    OR lower(name) LIKE '%naser%'
    OR name LIKE '%نصر%'
    OR lower(name) LIKE '%balkan%'
    OR name LIKE '%بالكنز%'
  );
