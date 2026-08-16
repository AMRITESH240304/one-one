/**
 * One-time backfill: removes "ghost" members — users whose Firebase account
 * was deleted before DELETE /v1/account existed. Those users still have rows
 * in groupMembers / memberAvailability / dailyUsage / chatUnread / userGroups
 * even though users/{uid} is gone.
 *
 * Detection: a member is a ghost when users/{uid} does not exist. Every real
 * user has a users record (created at startup and by requireActiveUser), so a
 * missing record means the account was deleted.
 *
 * Usage:
 *   npm run purge-ghosts                # real run
 *   npm run purge-ghosts -- --dry-run   # preview only, writes nothing
 *
 * Safe to run multiple times — purgeUserAccount is idempotent and skips
 * members whose rows are already gone.
 */
import { getRealtimeDatabase } from "../firebase/database.js";
import { requireFirebaseAdminApp } from "../firebase/adminApp.js";
import { logger } from "../logger.js";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  requireFirebaseAdminApp();
  const db = getRealtimeDatabase();

  logger.info(
    { checkpoint: "GHOST-PURGE-01", dryRun },
    "scanning groupMembers for ghost members"
  );

  const membersSnap = await db.ref("groupMembers").get();
  if (!isRecord(membersSnap.val())) {
    logger.info({ checkpoint: "GHOST-PURGE-02" }, "no groupMembers found; nothing to do");
    return;
  }

  // { userId: Set<groupId> }
  const groupsByUser = new Map<string, Set<string>>();
  for (const [groupId, rawMembers] of Object.entries(
    membersSnap.val() as Record<string, unknown>
  )) {
    if (!isRecord(rawMembers)) continue;
    for (const userId of Object.keys(rawMembers as Record<string, unknown>)) {
      let groups = groupsByUser.get(userId);
      if (!groups) {
        groups = new Set<string>();
        groupsByUser.set(userId, groups);
      }
      groups.add(groupId);
    }
  }

  logger.info(
    { checkpoint: "GHOST-PURGE-03", distinctMembers: groupsByUser.size },
    "distinct member ids collected"
  );

  // Batch-check which users still have a users record.
  const ghosts: Array<{ userId: string; groupIds: string[] }> = [];
  for (const [userId, groupIds] of groupsByUser) {
    const userSnap = await db.ref(`users/${userId}`).get();
    if (!userSnap.exists()) {
      ghosts.push({ userId, groupIds: Array.from(groupIds) });
    }
  }

  logger.info(
    { checkpoint: "GHOST-PURGE-04", ghostCount: ghosts.length },
    "ghost members detected"
  );

  if (dryRun) {
    for (const ghost of ghosts) {
      logger.info(
        {
          checkpoint: "GHOST-PURGE-DRY",
          userId: ghost.userId,
          groups: ghost.groupIds.length
        },
        "[dry-run] would purge ghost member"
      );
    }
    logger.info(
      { checkpoint: "GHOST-PURGE-DONE", dryRun: true, ghostCount: ghosts.length },
      "dry run complete — nothing was written"
    );
    return;
  }

  let purged = 0;
  for (const ghost of ghosts) {
    try {
      // Reuses the exact same logic as DELETE /v1/account: removes every
      // per-group row (and tears down groups this user owned).
      const { purgeUserAccount } = await import("../groups/groupService.js");
      await purgeUserAccount(ghost.userId);
      purged++;
      logger.info(
        {
          checkpoint: "GHOST-PURGE-05",
          userId: ghost.userId,
          groupsTouched: ghost.groupIds.length
        },
        "ghost member purged"
      );
    } catch (error) {
      logger.error(
        {
          checkpoint: "GHOST-PURGE-E1",
          userId: ghost.userId,
          error: error instanceof Error ? error.message : String(error)
        },
        "failed to purge ghost member"
      );
    }
  }

  logger.info(
    { checkpoint: "GHOST-PURGE-DONE", purged, total: ghosts.length },
    "ghost purge complete"
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    logger.error(
      {
        checkpoint: "GHOST-PURGE-E2",
        error: error instanceof Error ? error.message : String(error)
      },
      "ghost purge failed"
    );
    process.exit(1);
  });
