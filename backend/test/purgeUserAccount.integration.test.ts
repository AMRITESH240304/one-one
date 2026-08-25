/**
 * Live RTDB integration test for account purge.
 *
 * Seeds ephemeral membership rows under a synthetic uid, calls
 * purgeUserAccount, and asserts every per-group + user row is gone.
 * Skips when Firebase Admin env is not configured.
 */
import assert from "node:assert/strict";
import test from "node:test";
import { config as loadEnv } from "dotenv";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { deleteApp, getApps } from "firebase-admin/app";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: resolve(root, ".env"), quiet: true });

const hasFirebase =
  Boolean(process.env.FIREBASE_PROJECT_ID) &&
  Boolean(process.env.FIREBASE_CLIENT_EMAIL) &&
  Boolean(process.env.FIREBASE_PRIVATE_KEY) &&
  Boolean(process.env.FIREBASE_DATABASE_URL);

test(
  "purgeUserAccount removes the user from every group they belonged to",
  { skip: !hasFirebase },
  async () => {
    const { requireFirebaseAdminApp } = await import("../src/firebase/adminApp.js");
    const { getRealtimeDatabase } = await import("../src/firebase/database.js");
    const { purgeUserAccount } = await import("../src/groups/groupService.js");

    requireFirebaseAdminApp();
    const db = getRealtimeDatabase();

    const stamp = Date.now();
    const userId = `purge_test_${stamp}`;
    const groupId = `purge_test_group_${stamp}`;
    const now = Math.floor(stamp / 1000);

    await db.ref().update({
      [`users/${userId}`]: {
        displayName: "Purge Test User",
        accountState: "active",
        createdAt: now,
        updatedAt: now
      },
      [`groups/${groupId}`]: {
        name: "Purge Test Group",
        ownerUserId: "purge_test_other_owner",
        groupState: "active",
        createdAt: now,
        updatedAt: now,
        livekitRoomName: `purge-test-${stamp}`
      },
      [`groupMembers/${groupId}/${userId}`]: {
        role: "member",
        memberState: "active",
        mutedBySelf: false,
        joinedAt: now
      },
      [`groupMembers/${groupId}/purge_test_other_owner`]: {
        role: "owner",
        memberState: "active",
        mutedBySelf: false,
        joinedAt: now
      },
      [`userGroups/${userId}/${groupId}`]: {
        role: "member",
        joinedAt: now
      },
      [`memberAvailability/${groupId}/${userId}`]: {
        effectiveState: "away",
        updatedAt: now
      },
      [`dailyUsage/${groupId}/${userId}`]: { seconds: 1, updatedAt: now },
      [`chatUnread/${groupId}/${userId}`]: { count: 1, updatedAt: now },
      [`userDevices/${userId}/device1`]: {
        deviceState: "active",
        fcmToken: "purge-test-token",
        updatedAt: now
      },
      [`userSettings/${userId}`]: { theme: "dark" }
    });

    try {
      const beforeMember = await db.ref(`groupMembers/${groupId}/${userId}`).get();
      assert.equal(beforeMember.exists(), true, "seeded membership must exist");

      const result = await purgeUserAccount(userId);
      assert.equal(result.purged, true);
      assert.ok(result.groupsTouched >= 1);

      const [
        member,
        user,
        userGroups,
        availability,
        usage,
        unread,
        devices,
        settings,
        ownerStillThere
      ] = await Promise.all([
        db.ref(`groupMembers/${groupId}/${userId}`).get(),
        db.ref(`users/${userId}`).get(),
        db.ref(`userGroups/${userId}`).get(),
        db.ref(`memberAvailability/${groupId}/${userId}`).get(),
        db.ref(`dailyUsage/${groupId}/${userId}`).get(),
        db.ref(`chatUnread/${groupId}/${userId}`).get(),
        db.ref(`userDevices/${userId}`).get(),
        db.ref(`userSettings/${userId}`).get(),
        db.ref(`groupMembers/${groupId}/purge_test_other_owner`).get()
      ]);

      assert.equal(member.exists(), false, "membership row must be removed");
      assert.equal(user.exists(), false, "users record must be removed");
      assert.equal(userGroups.exists(), false, "userGroups index must be removed");
      assert.equal(availability.exists(), false, "availability must be removed");
      assert.equal(usage.exists(), false, "dailyUsage must be removed");
      assert.equal(unread.exists(), false, "chatUnread must be removed");
      assert.equal(devices.exists(), false, "userDevices must be removed");
      assert.equal(settings.exists(), false, "userSettings must be removed");
      assert.equal(
        ownerStillThere.exists(),
        true,
        "other members of the group must remain"
      );
    } finally {
      // Best-effort cleanup of the disposable group shell.
      await db.ref().update({
        [`groups/${groupId}`]: null,
        [`groupMembers/${groupId}`]: null,
        [`memberAvailability/${groupId}`]: null,
        [`dailyUsage/${groupId}`]: null,
        [`chatUnread/${groupId}`]: null,
        [`users/${userId}`]: null,
        [`userGroups/${userId}`]: null,
        [`userDevices/${userId}`]: null,
        [`userSettings/${userId}`]: null
      });
      // Release the Admin RTDB socket so node:test can exit.
      await Promise.all(getApps().map((app) => deleteApp(app)));
    }
  }
);
