CREATE TABLE "lustre_device_commands" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "kind" text NOT NULL,
  "payload" jsonb NOT NULL,
  "status" text DEFAULT 'pending' NOT NULL,
  "result" jsonb,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "acknowledged_at" timestamp with time zone
);
CREATE INDEX "lustre_device_commands_pending" ON "lustre_device_commands" USING btree ("device_id","status","created_at");
CREATE TABLE "lustre_device_job_status" (
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "job_id" uuid NOT NULL,
  "status" text NOT NULL,
  "progress" integer,
  "downloaded_bytes" bigint,
  "total_bytes" bigint,
  "phase" text,
  "attempts" integer NOT NULL,
  "updated_at" timestamp with time zone NOT NULL
);
CREATE UNIQUE INDEX "lustre_device_job_status_device_job" ON "lustre_device_job_status" USING btree ("device_id","job_id");
CREATE INDEX "lustre_device_job_status_device_updated" ON "lustre_device_job_status" USING btree ("device_id","updated_at");
