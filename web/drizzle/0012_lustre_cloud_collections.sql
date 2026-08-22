ALTER TABLE "lustre_watchlist_items" ADD COLUMN "deleted_at" timestamp with time zone;

CREATE TABLE "lustre_library_items" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "source_page_url" text NOT NULL,
  "title" text NOT NULL,
  "provider" text NOT NULL,
  "thumbnail_url" text,
  "media_kind" text DEFAULT 'video' NOT NULL,
  "completed_at" timestamp with time zone NOT NULL,
  "tags" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "collection" text,
  "favorite" boolean DEFAULT false NOT NULL,
  "deleted_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE UNIQUE INDEX "lustre_library_account_source" ON "lustre_library_items" ("account_id", "source_page_url");
CREATE INDEX "lustre_library_account_updated" ON "lustre_library_items" ("account_id", "updated_at");

CREATE TABLE "lustre_library_locations" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "library_item_id" uuid NOT NULL REFERENCES "lustre_library_items"("id"),
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "job_id" uuid NOT NULL,
  "destination" text DEFAULT 'local' NOT NULL,
  "display_filename" text,
  "byte_count" bigint,
  "state" text DEFAULT 'available' NOT NULL,
  "verified_at" timestamp with time zone,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE UNIQUE INDEX "lustre_library_location_device_job" ON "lustre_library_locations" ("device_id", "job_id");
CREATE INDEX "lustre_library_location_item" ON "lustre_library_locations" ("library_item_id", "updated_at");

CREATE TABLE "lustre_collection_mutations" (
  "id" uuid PRIMARY KEY NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE "lustre_collection_changes" (
  "sequence" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "entity_type" text NOT NULL,
  "entity_id" uuid NOT NULL,
  "operation" text NOT NULL,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "occurred_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE INDEX "lustre_collection_changes_account_sequence" ON "lustre_collection_changes" ("account_id", "sequence");
