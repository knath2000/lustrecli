import "server-only";
import { auth, currentUser } from "@clerk/nextjs/server";
import { db } from "@/lib/db/client";
import { lustreAccounts } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export type CurrentAccount = { id: string; authSubject: string; emailVerified: boolean };

export async function getCurrentAccount(): Promise<CurrentAccount | null> {
  let session;
  try { session = await auth(); } catch { console.error("cloud_current_account_failure", { stage: "clerk_session" }); throw new Error("current_account_unavailable"); }
  if (!session.isAuthenticated || !session.userId) return null;
  let user;
  try { user = await currentUser(); } catch { console.error("cloud_current_account_failure", { stage: "clerk_user" }); throw new Error("current_account_unavailable"); }
  const verified = user?.emailAddresses.some((email) => email.id === user.primaryEmailAddressId && email.verification?.status === "verified") ?? false;
  let account;
  try {
    const existing = await db.select().from(lustreAccounts).where(eq(lustreAccounts.authSubject, session.userId)).limit(1);
    account = existing[0] ?? (await db.insert(lustreAccounts).values({ authProvider: "clerk", authSubject: session.userId }).returning())[0];
  } catch { console.error("cloud_current_account_failure", { stage: "neon" }); throw new Error("current_account_unavailable"); }
  return { id: account.id, authSubject: session.userId, emailVerified: verified };
}

export async function requireCurrentAccount(requireVerifiedEmail = false): Promise<CurrentAccount> {
  const account = await getCurrentAccount();
  if (!account) throw new Error("unauthenticated");
  if (requireVerifiedEmail && !account.emailVerified) throw new Error("email_unverified");
  return account;
}
