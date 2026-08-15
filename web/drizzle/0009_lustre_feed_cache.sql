CREATE TABLE IF NOT EXISTS "lustre_feed_cache" (
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id") ON DELETE CASCADE,
  "provider" text NOT NULL,
  "normalized_query_hash" text NOT NULL,
  "page" integer NOT NULL CHECK ("page" > 0),
  "result" jsonb NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  PRIMARY KEY ("account_id", "provider", "normalized_query_hash", "page")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "lustre_feed_cache_expiry" ON "lustre_feed_cache" ("expires_at");
