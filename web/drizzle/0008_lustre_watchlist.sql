CREATE TABLE "lustre_watchlist_items" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "source_page_url" text NOT NULL,
  "title" text NOT NULL,
  "provider" text NOT NULL,
  "thumbnail_url" text,
  "watched" boolean NOT NULL DEFAULT false,
  "watched_at" timestamp with time zone,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at" timestamp with time zone NOT NULL DEFAULT now()
);
--> statement-breakpoint
CREATE UNIQUE INDEX "lustre_watchlist_account_source" ON "lustre_watchlist_items" ("account_id", "source_page_url");
--> statement-breakpoint
CREATE INDEX "lustre_watchlist_account_updated" ON "lustre_watchlist_items" ("account_id", "updated_at");
