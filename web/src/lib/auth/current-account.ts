import "server-only";
import { auth, currentUser } from "@clerk/nextjs/server";
import { db } from "@/lib/db/client";
import { lustreAccounts } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export type CurrentAccount = { id: string; authSubject: string; emailVerified: boolean };

export async function getCurrentAccount(): Promise<CurrentAccount | null> {
  const session = await auth();
  if (!session.isAuthenticated || !session.userId) return null;
  const user = await currentUser();
  const verified = user?.emailAddresses.some((email) => email.id === user.primaryEmailAddressId && email.verification?.status === "verified") ?? false;
  const existing = await db.select().from(lustreAccounts).where(eq(lustreAccounts.authSubject, session.userId)).limit(1);
  const account = existing[0] ?? (await db.insert(lustreAccounts).values({ authProvider: "clerk", authSubject: session.userId }).returning())[0];
  return { id: account.id, authSubject: session.userId, emailVerified: verified };
}

export async function requireCurrentAccount(requireVerifiedEmail = false): Promise<CurrentAccount> {
  const account = await getCurrentAccount();
  if (!account) throw new Error("unauthenticated");
  if (requireVerifiedEmail && !account.emailVerified) throw new Error("email_unverified");
  return account;
}
