CREATE TABLE "lustre_device_library_snapshots" (
  "device_id" uuid PRIMARY KEY NOT NULL REFERENCES "lustre_devices"("id"),
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "revision" bigint NOT NULL,
  "items" jsonb NOT NULL DEFAULT '[]'::jsonb,
  "synced_at" timestamp with time zone NOT NULL DEFAULT now()
);
CREATE INDEX "lustre_device_library_snapshots_account" ON "lustre_device_library_snapshots" ("account_id", "synced_at");
