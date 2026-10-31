-- Mobile owner-app: which report screens a non-owner may open.
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "report_keys" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];

-- Existing managers/accountants get the Owner-essentials pack until an owner edits them.
UPDATE "users"
SET "report_keys" = ARRAY[
  'sales_summary',
  'sales_detail',
  'costs',
  'open_orders',
  'order_detail'
]::TEXT[]
WHERE "role" = 'manager'
  AND (cardinality("report_keys") = 0);

UPDATE "users"
SET "report_keys" = ARRAY[
  'sales_summary',
  'sales_detail',
  'costs',
  'order_detail'
]::TEXT[]
WHERE "role" = 'accountant'
  AND (cardinality("report_keys") = 0);
