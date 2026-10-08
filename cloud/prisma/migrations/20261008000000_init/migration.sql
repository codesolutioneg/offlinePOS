-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "public";

-- CreateTable
CREATE TABLE "shops" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "pair_code_hash" TEXT NOT NULL,
    "key_id" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "shops_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "devices" (
    "id" TEXT NOT NULL,
    "shop_id" TEXT NOT NULL,
    "device_id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "app_version" TEXT NOT NULL,
    "token_hash" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "devices_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "backups" (
    "id" TEXT NOT NULL,
    "shop_id" TEXT NOT NULL,
    "device_row_id" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL,
    "received_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "size" INTEGER NOT NULL,
    "sha256" TEXT NOT NULL,
    "reason" TEXT NOT NULL,
    "key_id" TEXT NOT NULL,
    "path" TEXT NOT NULL,

    CONSTRAINT "backups_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "shops_pair_code_hash_key" ON "shops"("pair_code_hash");

-- CreateIndex
CREATE UNIQUE INDEX "devices_token_hash_key" ON "devices"("token_hash");

-- CreateIndex
CREATE UNIQUE INDEX "devices_shop_id_device_id_key" ON "devices"("shop_id", "device_id");

-- CreateIndex
CREATE INDEX "backups_shop_id_created_at_idx" ON "backups"("shop_id", "created_at");

-- CreateIndex
CREATE INDEX "backups_device_row_id_created_at_idx" ON "backups"("device_row_id", "created_at");

-- CreateIndex
CREATE UNIQUE INDEX "backups_shop_id_sha256_key" ON "backups"("shop_id", "sha256");

-- AddForeignKey
ALTER TABLE "devices" ADD CONSTRAINT "devices_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "shops"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "backups" ADD CONSTRAINT "backups_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "shops"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "backups" ADD CONSTRAINT "backups_device_row_id_fkey" FOREIGN KEY ("device_row_id") REFERENCES "devices"("id") ON DELETE CASCADE ON UPDATE CASCADE;
