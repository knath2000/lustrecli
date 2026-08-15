import "server-only";
import { requireCurrentAccount } from "@/lib/auth/current-account";

export async function watchAccountID() {
  return (await requireCurrentAccount()).id;
}
