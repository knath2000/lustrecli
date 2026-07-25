CREATE TABLE "lustre_device_presence" (
  "device_id" uuid PRIMARY KEY NOT NULL REFERENCES "lustre_devices"("id"),
  "connection_id" uuid NOT NULL,
  "connected_at" timestamptz NOT NULL,
  "last_heartbeat_at" timestamptz NOT NULL,
  "agent_version" text NOT NULL,
  "heartbeat_sequence" bigint NOT NULL,
  "updated_at" timestamptz NOT NULL
);
