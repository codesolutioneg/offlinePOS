-- Tax upload: mirror Dishflow ETA receipts into Postgres, submit from this site.

CREATE TABLE "tax_invoices" (
    "id" TEXT NOT NULL,
    "shop_id" TEXT NOT NULL,
    "connection_id" TEXT NOT NULL,
    "branch_name" TEXT NOT NULL DEFAULT '',
    "firebase_doc_id" TEXT,
    "order_number" TEXT NOT NULL DEFAULT '',
    "session_id" TEXT NOT NULL DEFAULT '',
    "business_date_key" TEXT NOT NULL DEFAULT '',
    "payment_method" TEXT NOT NULL DEFAULT '',
    "amount" DOUBLE PRECISION NOT NULL DEFAULT 0,
    "status" TEXT NOT NULL DEFAULT 'submitted',
    "eta_uuid" TEXT,
    "eta_long_id" TEXT,
    "eta_submission_id" TEXT,
    "eta_submitted_at" TIMESTAMP(3),
    "error" TEXT,
    "payload" JSONB NOT NULL,
    "batch_id" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "tax_invoices_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "tax_invoices_firebase_doc_id_key" ON "tax_invoices"("firebase_doc_id");
CREATE INDEX "tax_invoices_shop_id_connection_id_eta_submitted_at_idx" ON "tax_invoices"("shop_id", "connection_id", "eta_submitted_at");
CREATE INDEX "tax_invoices_shop_id_status_eta_submitted_at_idx" ON "tax_invoices"("shop_id", "status", "eta_submitted_at");
CREATE INDEX "tax_invoices_shop_id_session_id_idx" ON "tax_invoices"("shop_id", "session_id");

CREATE TABLE "tax_eta_settings" (
    "shop_id" TEXT NOT NULL,
    "firebase_project_id" TEXT NOT NULL DEFAULT '',
    "connection_id" TEXT NOT NULL DEFAULT '',
    "rin" TEXT NOT NULL DEFAULT '',
    "company_trade_name" TEXT NOT NULL DEFAULT '',
    "activity_code" TEXT NOT NULL DEFAULT '',
    "use_sandbox" BOOLEAN NOT NULL DEFAULT false,
    "integrations_json" JSONB NOT NULL,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "tax_eta_settings_pkey" PRIMARY KEY ("shop_id")
);

CREATE TABLE "tax_upload_batches" (
    "id" TEXT NOT NULL,
    "shop_id" TEXT NOT NULL,
    "connection_id" TEXT NOT NULL,
    "created_by" TEXT NOT NULL DEFAULT '',
    "status" TEXT NOT NULL DEFAULT 'running',
    "total" INTEGER NOT NULL DEFAULT 0,
    "accepted" INTEGER NOT NULL DEFAULT 0,
    "rejected" INTEGER NOT NULL DEFAULT 0,
    "error" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "finished_at" TIMESTAMP(3),

    CONSTRAINT "tax_upload_batches_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "tax_upload_batches_shop_id_created_at_idx" ON "tax_upload_batches"("shop_id", "created_at");

ALTER TABLE "tax_invoices" ADD CONSTRAINT "tax_invoices_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "shops"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "tax_invoices" ADD CONSTRAINT "tax_invoices_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "tax_upload_batches"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "tax_eta_settings" ADD CONSTRAINT "tax_eta_settings_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "shops"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "tax_upload_batches" ADD CONSTRAINT "tax_upload_batches_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "shops"("id") ON DELETE CASCADE ON UPDATE CASCADE;
