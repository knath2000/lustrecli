CREATE INDEX "lustre_device_commands_completed_ack"
ON "lustre_device_commands" USING btree ("account_id", "device_id", "kind", "acknowledged_at" DESC)
WHERE "status" = 'completed' AND "acknowledged_at" IS NOT NULL;
