import "server-only";
import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
import { drizzle as drizzlePostgres } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";

const databaseURL = process.env.DATABASE_URL;
if (!databaseURL) throw new Error("DATABASE_URL is not configured.");
export const db = drizzle({ client: neon(databaseURL), schema });
export const transactionDB = drizzlePostgres(postgres(databaseURL, { max: 1, prepare: false }), { schema });
