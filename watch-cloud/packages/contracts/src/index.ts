import { z } from "zod";

export const feedSiteIDSchema = z.enum(["allpornstream", "hqporner", "onlyfan420", "pornhub"]);
export type FeedSiteID = z.infer<typeof feedSiteIDSchema>;

export const feedSiteSchema = z.object({
  id: feedSiteIDSchema,
  displayName: z.string().min(1).max(80),
  homeURL: z.url({ protocol: /^https$/ }),
  supportsSearch: z.boolean(),
});
export type FeedSite = z.infer<typeof feedSiteSchema>;

const publicURL = z.url({ protocol: /^https$/ }).refine((value) => {
  const url = new URL(value);
  return !url.username && !url.password;
}, "URL must not contain credentials");

export const feedItemSchema = z.object({
  id: z.string().min(1).max(300),
  siteID: feedSiteIDSchema,
  title: z.string().min(1).max(1000),
  sourcePageURL: publicURL,
  thumbnailURL: publicURL.optional(),
  previewURLs: z.array(publicURL).max(4),
  uploadedAt: z.iso.datetime(),
  uploadedAtIsApproximate: z.boolean(),
  viewCount: z.number().int().nonnegative(),
  studio: z.string().max(300).optional(),
});
export type FeedItem = z.infer<typeof feedItemSchema>;

export const feedPageSchema = z.object({
  items: z.array(feedItemSchema).max(50),
  page: z.number().int().positive(),
  hasMore: z.boolean(),
});
export type FeedPage = z.infer<typeof feedPageSchema>;

export const playbackQualitySchema = z.object({
  label: z.string().min(1).max(80),
  url: publicURL,
  mediaKind: z.enum(["video", "hls"]),
  headers: z.partialRecord(z.enum(["Referer", "Origin", "User-Agent"]), z.string().max(1000)).default({}),
  provider: z.string().min(1).max(80).optional(),
  resolutionMethod: z.enum(["native", "browser_capture"]).optional(),
  infuseCompatibility: z.enum(["verified", "header_required", "unknown"]).optional(),
  stagingToken: z.string().min(32).max(8192).optional(),
});

export const providerAttemptSchema = z.object({
  provider: z.string().min(1).max(80),
  status: z.enum(["resolved", "verification_required", "failed", "unsupported"]),
  message: z.string().min(1).max(300).optional(),
});

export const feedPlaybackResolutionSchema = z.object({
  sourcePageURL: publicURL,
  title: z.string().min(1).max(1000),
  thumbnailURL: publicURL.optional(),
  clientResolverURL: publicURL.optional(),
  providerAttempts: z.array(providerAttemptSchema).max(12).optional(),
  qualities: z.array(playbackQualitySchema).min(1).max(12),
});
export type FeedPlaybackResolution = z.infer<typeof feedPlaybackResolutionSchema>;

export const errorCodeSchema = z.enum([
  "unsupported_provider",
  "verification_required",
  "provider_unavailable",
  "timeout",
  "rate_limit",
  "provider_changed",
  "invalid_request",
  "unauthorized",
]);
export type ErrorCode = z.infer<typeof errorCodeSchema>;

const resolutionProgressBase = z.object({
  at: z.iso.datetime(),
});

export const resolutionProgressEventSchema = z.discriminatedUnion("type", [
  resolutionProgressBase.extend({
    type: z.literal("started"),
    provider: z.string().min(1).max(80),
    message: z.string().min(1).max(300),
  }),
  resolutionProgressBase.extend({
    type: z.literal("metadata"),
    title: z.string().min(1).max(1000),
    thumbnailURL: publicURL.optional(),
    candidateCount: z.number().int().min(0).max(12).optional(),
  }),
  resolutionProgressBase.extend({
    type: z.literal("provider_started"),
    provider: z.string().min(1).max(80),
    message: z.string().min(1).max(300),
  }),
  resolutionProgressBase.extend({
    type: z.literal("provider_completed"),
    attempt: providerAttemptSchema,
    qualities: z.array(playbackQualitySchema).max(4).default([]),
  }),
  resolutionProgressBase.extend({
    type: z.literal("validating"),
    message: z.string().min(1).max(300),
  }),
  resolutionProgressBase.extend({
    type: z.literal("browser_required"),
    message: z.string().min(1).max(300),
    providerAttempts: z.array(providerAttemptSchema).max(12).default([]),
  }),
  resolutionProgressBase.extend({
    type: z.literal("completed"),
    resolution: feedPlaybackResolutionSchema,
  }),
  resolutionProgressBase.extend({
    type: z.literal("failed"),
    code: errorCodeSchema,
    message: z.string().min(1).max(500),
  }),
]);
export type ResolutionProgressEvent = z.infer<typeof resolutionProgressEventSchema>;

export const watchlistItemSchema = z.object({
  id: z.uuid(),
  sourcePageURL: publicURL,
  title: z.string().min(1).max(1000),
  provider: z.string().min(1).max(80),
  thumbnailURL: publicURL.nullable(),
  watched: z.boolean(),
  watchedAt: z.iso.datetime().nullable(),
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
});
export type WatchlistItem = z.infer<typeof watchlistItemSchema>;

export const resolveRequestSchema = z.object({ sourcePageURL: publicURL }).strict();

export const apiErrorSchema = z.object({
  error: z.object({ code: errorCodeSchema, message: z.string().min(1).max(500) }),
});

export class ResolverError extends Error {
  constructor(public readonly code: ErrorCode, message: string, public readonly status = 502) {
    super(message);
  }
}
