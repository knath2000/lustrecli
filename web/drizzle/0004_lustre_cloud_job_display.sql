ALTER TABLE "lustre_device_job_status" ADD COLUMN "display_name" text DEFAULT 'Download' NOT NULL;
ALTER TABLE "lustre_device_job_status" ADD COLUMN "preferred_quality_label" text;
