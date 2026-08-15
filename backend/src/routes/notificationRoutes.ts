import express, { Router } from "express";
import { z } from "zod";
import { getRealtimeDatabase } from "../firebase/database.js";
import { requireFirebaseAuth, type AuthenticatedRequest } from "../firebase/auth.js";
import { asyncHandler } from "../http/asyncHandler.js";
import {
  acknowledgeVoiceNudge,
  completeVoiceNudgeUpload,
  completeVoiceNudgeUploadWithContext,
  createVoiceNudge,
  initiateVoiceNudgeUpload,
  resolveVoiceNudgeAudioRedirect,
  sendRingNudge
} from "../notifications/voiceNudgeService.js";
import { maxVoiceNudgeBytes } from "../notifications/voiceNudgeValidation.js";
import { respondToNudge } from "../notifications/nudgeResponseService.js";
import { recordNudgeDelivery, verifyAckTicket } from "../notifications/nudgeDeliveryService.js";
import {
  sendChatMessageNotification,
  sendFriendLiveNotification,
  sendGoneOfflineNotification,
  sendNudgeNotification
} from "../notifications/notificationService.js";

const friendLiveSchema = z.object({
  deviceId: z.string().min(1),
  serviceSessionId: z.string().min(1),
  livekitSessionId: z.string().min(1)
});

const goneOfflineSchema = z.object({
  deviceId: z.string().min(1),
  reason: z.enum(["peer_left", "inactivity", "daily_usage_cap", "network_loss"])
});

const nudgeSchema = z.discriminatedUnion("targetScope", [
  z.object({
    targetScope: z.literal("single_friend"),
    targetUserId: z.string().min(1)
  }),
  z.object({
    targetScope: z.literal("all_friends")
  })
]);

const voiceNudgeQuerySchema = z.object({
  targetScope: z.enum(["single_friend", "all_friends"]),
  targetUserId: z.string().min(1).optional()
});

const recipientDeviceSchema = z.object({
  userId: z.string().min(1),
  deviceId: z.string().min(1),
  fcmToken: z.string().min(1),
  displayName: z.string().min(1).optional()
});

const voiceNudgeUploadSchema = z.discriminatedUnion("targetScope", [
  z.object({
    targetScope: z.literal("single_friend"),
    targetUserId: z.string().min(1),
    durationMs: z.number().int().positive(),
    // New fields — client provides these when reading RTDB directly.
    // Optional during migration; backend falls back to RTDB reads if missing.
    recipientDevices: z.array(recipientDeviceSchema).min(1).optional(),
    senderName: z.string().min(1).optional()
  }),
  z.object({
    targetScope: z.literal("all_friends"),
    durationMs: z.number().int().positive(),
    recipientDevices: z.array(recipientDeviceSchema).min(1).optional(),
    senderName: z.string().min(1).optional()
  })
]);

const voiceNudgeCompleteSchema = z.object({
  uploadTicket: z.string().min(1).optional()
});

const ringNudgeSchema = z.object({
  targetScope: z.enum(["single_friend", "all_friends"]),
  targetUserId: z.string().min(1).optional(),
  durationSeconds: z.union([z.literal(3), z.literal(5), z.literal(10)]),
  // Optional during migration; backend falls back to RTDB reads if missing.
  recipientDevices: z.array(recipientDeviceSchema).min(1).optional(),
  senderName: z.string().min(1).optional()
});

const voiceNudgeAckSchema = z.object({
  status: z.enum(["played", "failed"])
});

const nudgeAckSchema = z.object({
  status: z.enum(["played", "failed"]),
  reason: z.string().min(1).max(120).optional(),
  // Audibility concern for an otherwise-successful playback
  // (volume_muted / volume_low).
  attention: z.string().min(1).max(120).optional(),
  health: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])).optional()
});

const nudgeResponseSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("accept") }),
  z.object({ action: z.literal("decline") }),
  z.object({
    action: z.literal("snooze"),
    // Preserve compatibility with installed builds that sent a bare snooze.
    snoozeMinutes: z.union([z.literal(5), z.literal(15)]).default(5)
  })
]);

export function createNotificationRoutes() {
  const router = Router();

  router.post(
    "/v1/groups/:groupId/notifications/friend-live",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const body = friendLiveSchema.parse(request.body);
      const result = await sendFriendLiveNotification({
        groupId,
        senderUserId: authRequest.auth.uid,
        deviceId: body.deviceId,
        serviceSessionId: body.serviceSessionId,
        livekitSessionId: body.livekitSessionId
      });

      response.status(200).json(result);
    })
  );

  router.post(
    "/v1/groups/:groupId/notifications/gone-offline",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const body = goneOfflineSchema.parse(request.body);
      const result = await sendGoneOfflineNotification({
        groupId,
        userId: authRequest.auth.uid,
        deviceId: body.deviceId,
        reason: body.reason
      });

      response.status(200).json(result);
    })
  );

  router.post(
    "/v1/groups/:groupId/nudges",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const body = nudgeSchema.parse(request.body);
      const result = await sendNudgeNotification({
        groupId,
        senderUserId: authRequest.auth.uid,
        targetScope: body.targetScope,
        targetUserId: "targetUserId" in body ? body.targetUserId : undefined
      });

      response.status(200).json(result);
    })
  );

  router.post(
    "/v1/groups/:groupId/chat-messages/notify",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const result = await sendChatMessageNotification({
        groupId,
        senderUserId: authRequest.auth.uid
      });

      response.status(200).json(result);
    })
  );

  router.post(
    "/v1/groups/:groupId/nudges/:eventId/respond",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const eventId = z.string().min(1).parse(request.params.eventId);
      const body = nudgeResponseSchema.parse(request.body);
      response.status(200).json(
        await respondToNudge({
          groupId,
          eventId,
          responderUserId: authRequest.auth.uid,
          action: body.action,
          snoozeMinutes: body.action === "snooze" ? body.snoozeMinutes : undefined
        })
      );
    })
  );

  router.post(
    "/v1/groups/:groupId/ring-nudges",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const body = ringNudgeSchema.parse(request.body);

      // Backward compat: old clients don't send recipientDevices/senderName.
      let recipientDevices = body.recipientDevices;
      let senderName = body.senderName;

      if (!recipientDevices || !senderName) {
        const db = getRealtimeDatabase();

        const targetUserId = body.targetUserId;
        let recipientUserIds: string[];
        if (body.targetScope === "single_friend" && targetUserId) {
          recipientUserIds = targetUserId !== authRequest.auth.uid
            ? [targetUserId] : [];
        } else {
          const snap = await db.ref(`groupMembers/${groupId}`).get();
          recipientUserIds = [];
          if (snap.exists()) {
            const members = snap.val() as Record<string, unknown>;
            for (const [uid, val] of Object.entries(members)) {
              if (
                uid !== authRequest.auth.uid &&
                typeof val === "object" && val !== null &&
                (val as Record<string, unknown>).memberState === "active"
              ) {
                recipientUserIds.push(uid);
              }
            }
          }
        }

        const devices: Array<{ userId: string; deviceId: string; fcmToken: string; displayName?: string }> = [];
        for (const uid of recipientUserIds) {
          const devSnap = await db.ref(`userDevices/${uid}`).get();
          if (!devSnap.exists()) continue;
          const recipientDisplayName = await readDisplayNameForAck(db, uid);
          const devs = devSnap.val() as Record<string, unknown>;
          for (const [devId, dv] of Object.entries(devs)) {
            if (
              typeof dv === "object" && dv !== null &&
              (dv as Record<string, unknown>).deviceState === "active" &&
              (dv as Record<string, unknown>).platform === "android"
            ) {
              const tok = (dv as Record<string, unknown>).fcmToken;
              if (typeof tok === "string" && tok) {
                devices.push({ userId: uid, deviceId: devId, fcmToken: tok, displayName: recipientDisplayName });
              }
            }
          }
        }
        recipientDevices = devices;

        const nameSnap = await db.ref(`users/${authRequest.auth.uid}/displayName`).get();
        senderName = nameSnap.val()?.toString() || "Someone";
      }

      const result = await sendRingNudge({
        groupId,
        senderUserId: authRequest.auth.uid,
        targetScope: body.targetScope,
        targetUserId: body.targetUserId,
        durationSeconds: body.durationSeconds,
        recipientDevices: recipientDevices!,
        senderName: senderName!
      });
      response.status(200).json(result);
    })
  );

  router.post(
    "/v1/groups/:groupId/voice-nudges/uploads",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const body = voiceNudgeUploadSchema.parse(request.body);

      // Backward compat: old clients don't send recipientDevices/senderName.
      // Fall back to RTDB reads until all clients are updated.
      let recipientDevices = body.recipientDevices;
      let senderName = body.senderName;
      let db: ReturnType<typeof getRealtimeDatabase> | undefined;

      if (!recipientDevices || !senderName) {
        db = getRealtimeDatabase();

        // Resolve recipients
        const targetUserId =
          "targetUserId" in body ? body.targetUserId : undefined;
        let recipientUserIds: string[];
        if (targetUserId) {
          recipientUserIds = targetUserId !== authRequest.auth.uid
            ? [targetUserId]
            : [];
        } else {
          const memberSnap = await db.ref(`groupMembers/${groupId}`).get();
          recipientUserIds = [];
          if (memberSnap.exists()) {
            const members = memberSnap.val() as Record<string, unknown>;
            for (const [uid, val] of Object.entries(members)) {
              if (
                uid !== authRequest.auth.uid &&
                typeof val === "object" && val !== null &&
                (val as Record<string, unknown>).memberState === "active"
              ) {
                recipientUserIds.push(uid);
              }
            }
          }
        }

        // Read recipient devices (FCM tokens) from RTDB
        const devices: Array<{ userId: string; deviceId: string; fcmToken: string; displayName?: string }> = [];
        for (const uid of recipientUserIds) {
          const devSnap = await db.ref(`userDevices/${uid}`).get();
          if (!devSnap.exists()) continue;
          const recipientDisplayName = await readDisplayNameForAck(db, uid);
          const devs = devSnap.val() as Record<string, unknown>;
          for (const [devId, dv] of Object.entries(devs)) {
            if (
              typeof dv === "object" && dv !== null &&
              (dv as Record<string, unknown>).deviceState === "active" &&
              (dv as Record<string, unknown>).platform === "android"
            ) {
              const tok = (dv as Record<string, unknown>).fcmToken;
              if (typeof tok === "string" && tok) {
                devices.push({ userId: uid, deviceId: devId, fcmToken: tok, displayName: recipientDisplayName });
              }
            }
          }
        }
        recipientDevices = devices;

        // Read display name from RTDB
        const nameSnap = await db.ref(`users/${authRequest.auth.uid}/displayName`).get();
        senderName = nameSnap.val()?.toString() || "Someone";
      }

      const result = await initiateVoiceNudgeUpload({
        groupId,
        senderUserId: authRequest.auth.uid,
        targetScope: body.targetScope,
        targetUserId: "targetUserId" in body ? body.targetUserId : undefined,
        durationMs: body.durationMs,
        recipientDevices: recipientDevices!,
        senderName: senderName!
      });

      // Backward compat: write RTDB metadata so the legacy /complete
      // handler can find it when the old client sends {} instead of uploadTicket.
      if (!body.recipientDevices || !body.senderName) {
        const now = Math.floor(Date.now() / 1000);
        const rtUserIds = [...new Set((recipientDevices ?? []).map((d: { userId: string }) => d.userId))]
          .filter((uid: string) => uid !== authRequest.auth.uid);
        await db!.ref().update({
          [`voiceNudges/${result.notificationEventId}/eventId`]: result.notificationEventId,
          [`voiceNudges/${result.notificationEventId}/groupId`]: groupId,
          [`voiceNudges/${result.notificationEventId}/senderUserId`]: authRequest.auth.uid,
          [`voiceNudges/${result.notificationEventId}/storagePath`]: result.storagePath,
          [`voiceNudges/${result.notificationEventId}/expiresAt`]: result.expiresAt,
          [`voiceNudges/${result.notificationEventId}/uploadExpiresAt`]: result.uploadExpiresAt,
          [`voiceNudges/${result.notificationEventId}/durationMs`]: body.durationMs,
          [`voiceNudges/${result.notificationEventId}/targetScope`]: body.targetScope,
          [`voiceNudges/${result.notificationEventId}/targetUserIds`]: rtUserIds,
          [`voiceNudges/${result.notificationEventId}/recipientDevices`]: recipientDevices,
          [`voiceNudges/${result.notificationEventId}/senderName`]: senderName,
          [`voiceNudges/${result.notificationEventId}/voiceNudgeState`]: "awaiting_upload",
          [`voiceNudges/${result.notificationEventId}/createdAt`]: now
        }).catch(() => undefined);
      }

      response.status(201).json(result);
    })
  );

  router.post(
    "/v1/groups/:groupId/voice-nudges/:eventId/complete",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const eventId = z.string().min(1).parse(request.params.eventId);
      const body = voiceNudgeCompleteSchema.parse(request.body);

      if (body.uploadTicket) {
        // New zero-RTDB flow
        const result = await completeVoiceNudgeUpload({ uploadTicket: body.uploadTicket });
        response.status(200).json(result);
        return;
      }

      // Legacy fallback: old client sends {} — read context from RTDB
      const db = getRealtimeDatabase();
      const snap = await db.ref(`voiceNudges/${eventId}`).get();
      if (!snap.exists()) {
        response.status(404).json({ error: "voice_nudge_not_found", message: "Voice nudge does not exist." });
        return;
      }
      const v = snap.val() as Record<string, unknown>;
      if (String(v.groupId ?? "") !== groupId) {
        response.status(404).json({ error: "voice_nudge_not_found", message: "Voice nudge does not exist." });
        return;
      }
      if (String(v.senderUserId ?? "") !== authRequest.auth.uid) {
        response.status(403).json({ error: "voice_nudge_forbidden", message: "Only the sender can complete this upload." });
        return;
      }

      const state = String(v.voiceNudgeState ?? "");
      if (state !== "awaiting_upload") {
        if (state === "pending" || state === "sent" || state === "completed") {
          response.status(200).json({ notificationEventId: eventId, recipientUsers: 0, targetDevices: 0, sent: 0, failed: 0, skipped: 0, alreadyComplete: true });
          return;
        }
        response.status(409).json({ error: "voice_nudge_not_awaiting_upload", message: "Voice nudge is not waiting for an upload." });
        return;
      }

      const uploadExpiresAt = Number(v.uploadExpiresAt) || 0;
      if (uploadExpiresAt > 0 && uploadExpiresAt < Math.floor(Date.now() / 1000)) {
        await db.ref(`voiceNudges/${eventId}`).update({ voiceNudgeState: "upload_expired" }).catch(() => undefined);
        response.status(410).json({ error: "voice_nudge_upload_expired", message: "Voice nudge upload URL has expired." });
        return;
      }

      const storagePath = String(v.storagePath ?? "");
      if (!storagePath) {
        response.status(500).json({ error: "voice_nudge_storage_missing", message: "Voice nudge storage path is missing." });
        return;
      }

      const recipientDevices = Array.isArray(v.recipientDevices)
        ? (v.recipientDevices as Array<{ userId: string; deviceId: string; fcmToken: string }>)
        : [];
      const recipientUserIds = Array.isArray(v.targetUserIds) ? v.targetUserIds.map(String) : [];

      const result = await completeVoiceNudgeUploadWithContext({
        eventId,
        groupId,
        senderUserId: authRequest.auth.uid,
        senderName: String(v.senderName ?? "Someone"),
        durationMs: Number(v.durationMs) || 0,
        expiresAt: Number(v.expiresAt) || (Math.floor(Date.now() / 1000) + 600),
        storagePath,
        recipientUserIds,
        recipientDevices
      });

      // Clean up RTDB after dispatch
      await db.ref(`voiceNudges/${eventId}`).update({ voiceNudgeState: "sent" }).catch(() => undefined);

      response.status(200).json(result);
    })
  );

  // Legacy: raw audio through the API. Prefer /voice-nudges/uploads + /complete.
  router.post(
    "/v1/groups/:groupId/voice-nudges",
    requireFirebaseAuth,
    express.raw({ type: ["audio/mp4", "application/octet-stream"], limit: maxVoiceNudgeBytes }),
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = z.string().min(1).parse(request.params.groupId);
      const query = voiceNudgeQuerySchema.parse(request.query);
      const durationMs = z.coerce
        .number()
        .int()
        .positive()
        .parse(request.header("x-voice-duration-ms"));
      if (!Buffer.isBuffer(request.body)) {
        response.status(415).json({
          error: "unsupported_media_type",
          message: "Voice nudge body must use audio/mp4."
        });
        return;
      }

      const result = await createVoiceNudge({
        groupId,
        senderUserId: authRequest.auth.uid,
        targetScope: query.targetScope,
        targetUserId: query.targetUserId,
        durationMs,
        audio: request.body
      });
      response.status(201).json(result);
    })
  );

  // Deprecated — audio is delivered via signed URL in the FCM payload.
  // Kept for backward compatibility; throws 410 for any caller.
  router.get(
    "/v1/voice-nudges/:eventId/audio",
    asyncHandler(async (request, response) => {
      const eventId = z.string().min(1).parse(request.params.eventId);
      const token = request.header("x-one-one-delivery-token") ?? "";
      // resolveVoiceNudgeAudioRedirect now throws HttpError(410) — audio
      // must be fetched via the signed URL in the FCM data payload.
      await resolveVoiceNudgeAudioRedirect(eventId, token);
    })
  );

  router.post(
    "/v1/voice-nudges/:eventId/ack",
    asyncHandler(async (request, response) => {
      const eventId = z.string().min(1).parse(request.params.eventId);
      const token = request.header("x-one-one-delivery-token") ?? "";
      const body = voiceNudgeAckSchema.parse(request.body);
      response.status(200).json(await acknowledgeVoiceNudge(eventId, token, body.status));
    })
  );

  // Real-time delivery confirmation for ring + voice nudges. The receiving
  // device calls this the moment the nudge genuinely starts playing (or
  // definitively fails to), and the sender is pushed a live result. No auth
  // header required — the signed ack ticket itself is the credential.
  router.post(
    "/v1/nudges/:eventId/ack",
    asyncHandler(async (request, response) => {
      const eventId = z.string().min(1).parse(request.params.eventId);
      const token = request.header("x-one-one-delivery-token") ?? "";
      const ticket = verifyAckTicket(token);
      if (ticket.eventId !== eventId) {
        response.status(403).json({ error: "invalid_ack_ticket", message: "Delivery token does not match this event." });
        return;
      }
      const body = nudgeAckSchema.parse(request.body);
      const result = await recordNudgeDelivery({
        ticket,
        status: body.status,
        reason: body.reason,
        attention: body.attention,
        health: body.health
      });
      response.status(200).json(result);
    })
  );

  return router;
}

async function readDisplayNameForAck(
  db: ReturnType<typeof getRealtimeDatabase>,
  userId: string
): Promise<string | undefined> {
  const snapshot = await db.ref(`users/${userId}/displayName`).get();
  const name = snapshot.val()?.toString().trim();
  return name || undefined;
}
