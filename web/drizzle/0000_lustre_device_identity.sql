CREATE TABLE "lustre_accounts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "auth_provider" text NOT NULL,
  "auth_subject" text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "disabled_at" timestamptz
);
CREATE UNIQUE INDEX "lustre_accounts_provider_subject" ON "lustre_accounts" ("auth_provider", "auth_subject");

CREATE TABLE "lustre_devices" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "public_key" text NOT NULL,
  "key_thumbprint" text NOT NULL,
  "display_name" text NOT NULL,
  "platform" text NOT NULL,
  "agent_version" text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "last_authenticated_at" timestamptz,
  "revoked_at" timestamptz
);
CREATE UNIQUE INDEX "lustre_devices_thumbprint" ON "lustre_devices" ("key_thumbprint");
CREATE INDEX "lustre_devices_account" ON "lustre_devices" ("account_id");

CREATE TABLE "lustre_pairing_challenges" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "code_hash" text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "consumed_at" timestamptz,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE UNIQUE INDEX "lustre_pairing_challenges_code_hash" ON "lustre_pairing_challenges" ("code_hash");
CREATE INDEX "lustre_pairing_challenges_account" ON "lustre_pairing_challenges" ("account_id");

CREATE TABLE "lustre_device_enrollments" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "pairing_challenge_id" uuid NOT NULL REFERENCES "lustre_pairing_challenges"("id"),
  "public_key" text NOT NULL,
  "key_thumbprint" text NOT NULL,
  "display_name" text NOT NULL,
  "platform" text NOT NULL,
  "agent_version" text NOT NULL,
  "nonce" text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "consumed_at" timestamptz,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE "lustre_device_session_challenges" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "nonce" text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "consumed_at" timestamptz,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE "lustre_device_audit_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "account_id" uuid NOT NULL REFERENCES "lustre_accounts"("id"),
  "device_id" uuid NOT NULL REFERENCES "lustre_devices"("id"),
  "kind" text NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "occurred_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE "lustre_rate_limits" (
  "bucket" text PRIMARY KEY NOT NULL,
  "count" integer NOT NULL,
  "resets_at" timestamptz NOT NULL
);
