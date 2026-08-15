import "server-only";
import postgres from "postgres";

let client: ReturnType<typeof postgres> | undefined;

export function watchDB() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required.");
  client ??= postgres(url, {
    max: 4,
    idle_timeout: 20,
    connect_timeout: 10,
    prepare: false,
  });
  return client;
}
