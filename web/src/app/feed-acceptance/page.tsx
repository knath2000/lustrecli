import { auth } from "@clerk/nextjs/server";
import { notFound } from "next/navigation";
import { cloudFeedAcceptanceAllowed, cloudFeedMediaEnabled } from "@/lib/cloud-feed-ui";
import { CloudFullDashboard } from "../cloud-full-dashboard";

export default async function FeedAcceptancePage() {
  const { userId } = await auth();
  if (!cloudFeedAcceptanceAllowed(
    process.env.LUSTRE_CLOUD_FEED_ACCEPTANCE_ENABLED,
    process.env.LUSTRE_CLOUD_FEED_ACCEPTANCE_AUTH_SUBJECT,
    userId,
  )) notFound();

  return <CloudFullDashboard
    feedEnabled
    feedMediaEnabled={cloudFeedMediaEnabled(process.env.LUSTRE_CLOUD_FEED_MEDIA_ENABLED)}
    suppressDestinationPolling
  />;
}
