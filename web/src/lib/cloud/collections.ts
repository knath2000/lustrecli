import { and, asc, eq, gt, isNull } from "drizzle-orm";
import { db, transactionDB } from "@/lib/db/client";
import {
  lustreCollectionChanges,
  lustreCollectionMutations,
  lustreLibraryItems,
  lustreLibraryLocations,
  lustreWatchlistItems,
} from "@/lib/db/schema";

export type CollectionMutation = {
  id: string;
  kind: "watchlist_upsert" | "watchlist_delete" | "library_upsert" | "library_organize" | "library_delete";
  sourcePageURL: string;
  payload: Record<string, unknown>;
};

function watchlistPayload(item: typeof lustreWatchlistItems.$inferSelect) {
  return {
    id: item.id,
    sourcePageURL: item.sourcePageURL,
    title: item.title,
    provider: item.provider,
    thumbnailURL: item.thumbnailURL,
    watched: item.watched,
    watchedAt: item.watchedAt?.toISOString() ?? null,
    createdAt: item.createdAt.toISOString(),
    updatedAt: item.updatedAt.toISOString(),
  };
}

function libraryPayload(item: typeof lustreLibraryItems.$inferSelect) {
  return {
    id: item.id,
    sourcePageURL: item.sourcePageURL,
    title: item.title,
    provider: item.provider,
    thumbnailURL: item.thumbnailURL,
    mediaKind: item.mediaKind,
    completedAt: item.completedAt.toISOString(),
    tags: item.tags,
    collection: item.collection,
    favorite: item.favorite,
    createdAt: item.createdAt.toISOString(),
    updatedAt: item.updatedAt.toISOString(),
  };
}

export async function recordCollectionChange(
  accountID: string,
  entityType: "watchlist" | "library",
  entityID: string,
  operation: "upsert" | "delete",
  payload: Record<string, unknown>,
) {
  await db.insert(lustreCollectionChanges).values({ accountID, entityType, entityID, operation, payload });
}

export async function synchronizeCollections(
  accountID: string,
  deviceID: string,
  cursor: number,
  mutations: CollectionMutation[],
) {
  await transactionDB.transaction(async (tx) => {
    for (const mutation of mutations) {
      const inserted = await tx.insert(lustreCollectionMutations).values({
        id: mutation.id,
        accountID,
        deviceID,
      }).onConflictDoNothing().returning({ id: lustreCollectionMutations.id });
      if (!inserted[0]) continue;

      if (mutation.kind === "watchlist_upsert") {
        const [item] = await tx.insert(lustreWatchlistItems).values({
          accountID,
          sourcePageURL: mutation.sourcePageURL,
          title: mutation.payload.title as string,
          provider: mutation.payload.provider as string,
          thumbnailURL: mutation.payload.thumbnailURL as string | null,
          watched: mutation.payload.watched as boolean,
          watchedAt: mutation.payload.watched === true ? new Date() : null,
          deletedAt: null,
          updatedAt: new Date(),
        }).onConflictDoUpdate({
          target: [lustreWatchlistItems.accountID, lustreWatchlistItems.sourcePageURL],
          set: {
            title: mutation.payload.title as string,
            provider: mutation.payload.provider as string,
            thumbnailURL: mutation.payload.thumbnailURL as string | null,
            watched: mutation.payload.watched as boolean,
            watchedAt: mutation.payload.watched === true ? new Date() : null,
            deletedAt: null,
            updatedAt: new Date(),
          },
        }).returning();
        await tx.insert(lustreCollectionChanges).values({
          accountID,
          entityType: "watchlist",
          entityID: item.id,
          operation: "upsert",
          payload: watchlistPayload(item),
        });
      } else if (mutation.kind === "watchlist_delete") {
        const [item] = await tx.update(lustreWatchlistItems).set({ deletedAt: new Date(), updatedAt: new Date() }).where(and(
          eq(lustreWatchlistItems.accountID, accountID),
          eq(lustreWatchlistItems.sourcePageURL, mutation.sourcePageURL),
        )).returning();
        if (item) await tx.insert(lustreCollectionChanges).values({ accountID, entityType: "watchlist", entityID: item.id, operation: "delete", payload: { sourcePageURL: item.sourcePageURL } });
      } else if (mutation.kind === "library_upsert") {
        const completedAt = new Date(mutation.payload.completedAt as string);
        const [existing] = await tx.select().from(lustreLibraryItems).where(and(
          eq(lustreLibraryItems.accountID, accountID),
          eq(lustreLibraryItems.sourcePageURL, mutation.sourcePageURL),
        )).limit(1);
        const staleDeletedCompletion = existing?.deletedAt && completedAt <= existing.deletedAt;
        const [saved] = staleDeletedCompletion ? [existing] : await tx.insert(lustreLibraryItems).values({
            accountID,
            sourcePageURL: mutation.sourcePageURL,
            title: mutation.payload.title as string,
            provider: mutation.payload.provider as string,
            thumbnailURL: mutation.payload.thumbnailURL as string | null,
            mediaKind: mutation.payload.mediaKind as string,
            completedAt,
            deletedAt: null,
            updatedAt: new Date(),
          }).onConflictDoUpdate({
            target: [lustreLibraryItems.accountID, lustreLibraryItems.sourcePageURL],
            set: {
              title: mutation.payload.title as string,
              provider: mutation.payload.provider as string,
              thumbnailURL: mutation.payload.thumbnailURL as string | null,
              mediaKind: mutation.payload.mediaKind as string,
              completedAt,
              deletedAt: null,
              updatedAt: new Date(),
            },
          }).returning();
        const item = saved;
        await tx.insert(lustreLibraryLocations).values({
          libraryItemID: item.id,
          accountID,
          deviceID,
          jobID: mutation.payload.jobID as string,
          destination: "local",
          displayFilename: mutation.payload.displayFilename as string | null,
          byteCount: mutation.payload.byteCount as number | null,
          state: "available",
          verifiedAt: new Date(),
          updatedAt: new Date(),
        }).onConflictDoUpdate({
          target: [lustreLibraryLocations.deviceID, lustreLibraryLocations.jobID],
          set: {
            libraryItemID: item.id,
            displayFilename: mutation.payload.displayFilename as string | null,
            byteCount: mutation.payload.byteCount as number | null,
            state: "available",
            verifiedAt: new Date(),
            updatedAt: new Date(),
          },
        });
        if (!staleDeletedCompletion) await tx.insert(lustreCollectionChanges).values({ accountID, entityType: "library", entityID: item.id, operation: "upsert", payload: libraryPayload(item) });
      } else if (mutation.kind === "library_organize") {
        const [item] = await tx.update(lustreLibraryItems).set({
          tags: mutation.payload.tags as string[],
          collection: mutation.payload.collection as string | null,
          favorite: mutation.payload.favorite as boolean,
          updatedAt: new Date(),
        }).where(and(
          eq(lustreLibraryItems.accountID, accountID),
          eq(lustreLibraryItems.sourcePageURL, mutation.sourcePageURL),
          isNull(lustreLibraryItems.deletedAt),
        )).returning();
        if (item) await tx.insert(lustreCollectionChanges).values({ accountID, entityType: "library", entityID: item.id, operation: "upsert", payload: libraryPayload(item) });
      } else {
        const [item] = await tx.update(lustreLibraryItems).set({ deletedAt: new Date(), updatedAt: new Date() }).where(and(
          eq(lustreLibraryItems.accountID, accountID),
          eq(lustreLibraryItems.sourcePageURL, mutation.sourcePageURL),
        )).returning();
        if (item) await tx.insert(lustreCollectionChanges).values({ accountID, entityType: "library", entityID: item.id, operation: "delete", payload: { sourcePageURL: item.sourcePageURL } });
      }
    }
  });

  const changes = await db.select().from(lustreCollectionChanges).where(and(
    eq(lustreCollectionChanges.accountID, accountID),
    gt(lustreCollectionChanges.sequence, cursor),
  )).orderBy(asc(lustreCollectionChanges.sequence)).limit(101);
  const page = changes.slice(0, 100);
  const bootstrap = cursor === 0 && mutations.length === 0 ? {
    watchlist: (await db.select().from(lustreWatchlistItems).where(and(
      eq(lustreWatchlistItems.accountID, accountID),
      isNull(lustreWatchlistItems.deletedAt),
    ))).map(watchlistPayload),
    library: (await db.select().from(lustreLibraryItems).where(and(
      eq(lustreLibraryItems.accountID, accountID),
      isNull(lustreLibraryItems.deletedAt),
    ))).map(libraryPayload),
  } : null;
  return {
    cursor: page.at(-1)?.sequence ?? cursor,
    hasMore: changes.length > 100,
    acknowledgedMutationIDs: mutations.map((mutation) => mutation.id),
    bootstrap,
    changes: page.map((change) => ({
      sequence: change.sequence,
      entityType: change.entityType,
      entityID: change.entityID,
      operation: change.operation,
      payload: change.payload,
      occurredAt: change.occurredAt.toISOString(),
    })),
  };
}
