CREATE TABLE "lustre_cloud_stages" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "modal_call_id" text,
  "object_key" text NOT NULL,
  "filename" text NOT NULL,
  "status" text DEFAULT 'pending' NOT NULL,
  "progress_bytes" bigint DEFAULT 0 NOT NULL,
  "total_bytes" bigint,
  "sha256" text,
  "failure_code" text,
  "reserved_byte_hours" bigint NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "delivered_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE INDEX "lustre_cloud_stages_device_status" ON "lustre_cloud_stages" ("device_id", "status");
CREATE INDEX "lustre_cloud_stages_expiry" ON "lustre_cloud_stages" ("expires_at");
