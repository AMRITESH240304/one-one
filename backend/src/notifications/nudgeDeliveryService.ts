import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { getRealtimeDatabase } from "../firebase/database.js";
import { sendAndroidDataPushes } from "../firebase/messaging.js";
import { HttpError } from "../http/httpError.js";
import { logger } from "../logger.js";

// ---------------------------------------------------------------------------
// Ack ticket — a self-contained, HMAC-signed token handed to the receiving
// device instead of an opaque per-device secret. It carries everything the
// ack endpoint needs (event, sender, recipient) so acknowledging a nudge
// costs zero RTDB reads, mirroring the upload-ticket pattern used for the
// voice-nudge upload flow.
// ---------------------------------------------------------------------------

const ackTicketSecret = (() => {
  if (process.env.NUDGE_ACK_TICKET_SECRET) {
    return Buffer.from(process.env.NUDGE_ACK_TICKET_SECRET, "base64url");
  }
  // Ephemeral secret — outstanding tickets won't survive a restart, which
  // just means an in-flight nudge's ack silently no-ops. Acceptable; the
  // notification itself was already delivered independently of this.
  return randomBytes(32);
})();

export type NudgeKind = "ring_nudge" | "voice_nudge" | "nudge";

export type AckTicket = {
  eventId: string;
  groupId: string;
  kind: NudgeKind;
  senderUserId: string;
  recipientUserId: string;
  recipientName: string;
  iat: number;
};

export function createAckTicket(payload: Omit<AckTicket, "iat">): string {
  const full: AckTicket = { ...payload, iat: nowSeconds() };
  const encoded = Buffer.from(JSON.stringify(full), "utf8").toString("base64url");
  const sig = createHmac("sha256", ackTicketSecret).update(encoded).digest("base64url");
  return `${encoded}.${sig}`;
}

export function verifyAckTicket(ticket: string): AckTicket {
  const dot = ticket.lastIndexOf(".");
  if (dot < 0) {
    throw new HttpError(403, "invalid_ack_ticket", "Delivery token is malformed.");
  }
  const encoded = ticket.slice(0, dot);
  const sig = ticket.slice(dot + 1);

  const expected = createHmac("sha256", ackTicketSecret).update(encoded).digest("base64url");
  const sigBuf = Buffer.from(sig, "base64url");
  const expBuf = Buffer.from(expected, "base64url");
  if (sigBuf.length !== expBuf.length || !timingSafeEqual(sigBuf, expBuf)) {
    throw new HttpError(403, "invalid_ack_ticket", "Delivery token signature is invalid.");
  }

  let raw: unknown;
  try {
    raw = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new HttpError(403, "invalid_ack_ticket", "Delivery token payload is corrupt.");
  }
  if (!isAckTicket(raw)) {
    throw new HttpError(403, "invalid_ack_ticket", "Delivery token payload is invalid.");
  }
  return raw;
}

function isAckTicket(value: unknown): value is AckTicket {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.eventId === "string" &&
    typeof v.groupId === "string" &&
    (v.kind === "ring_nudge" || v.kind === "voice_nudge" || v.kind === "nudge") &&
    typeof v.senderUserId === "string" &&
    typeof v.recipientUserId === "string" &&
    typeof v.recipientName === "string" &&
    typeof v.iat === "number"
  );
}

// ---------------------------------------------------------------------------
// recordNudgeDelivery — called once the receiver's device has genuinely
// started playing a ring/voice nudge, posted a notify/push notification,
// or definitively failed to. Persists the outcome and pushes a real-time
// result back to the sender so they see "received", not just "sent".
// ---------------------------------------------------------------------------

export type NudgeDeliveryStatus = "played" | "failed";

export type RecordNudgeDeliveryInput = {
  ticket: AckTicket;
  status: NudgeDeliveryStatus;
  reason?: string;
  /** Audibility concern for an otherwise-successful playback (mute/low). */
  attention?: string;
  health?: Record<string, unknown>;
};

export async function recordNudgeDelivery(input: RecordNudgeDeliveryInput) {
  const { ticket, status, reason, attention, health } = input;
  const now = nowSeconds();

  // Audit writes (per-event record + per-recipient rollup) run in the
  // background. They must never delay the real-time sender confirmation, so
  // the sender push below starts without waiting on these RTDB round trips.
  void persistDeliveryAudit({ ticket, status, reason, attention, health, now });

  const senderDevices = await collectAndroidDevices(ticket.senderUserId);
  if (senderDevices.length === 0) {
    return {
      eventId: ticket.eventId,
      status,
      reason: reason ?? null,
      attention: attention ?? null,
      notifiedSenderDevices: 0
    };
  }

  const pushResult = await sendAndroidDataPushes(
    senderDevices.map((fcmToken) => ({
      token: fcmToken,
      data: {
        type: "nudge_delivery_result",
        eventId: ticket.eventId,
        groupId: ticket.groupId,
        kind: ticket.kind,
        recipientUserId: ticket.recipientUserId,
        recipientName: ticket.recipientName,
        status,
        reason: reason ?? "",
        attention: attention ?? ""
      }
    })),
    30 * 1000
  );

  return {
    eventId: ticket.eventId,
    status,
    reason: reason ?? null,
    attention: attention ?? null,
    notifiedSenderDevices: senderDevices.length,
    sent: pushResult.successCount
  };
}

/**
 * Background audit persistence for a delivery outcome. Runs independently of
 * the sender confirmation push so RTDB write/transaction latency never delays
 * the sender from seeing "played". Both writes are individually non-fatal.
 */
async function persistDeliveryAudit(input: {
  ticket: AckTicket;
  status: NudgeDeliveryStatus;
  reason?: string;
  attention?: string;
  health?: Record<string, unknown>;
  now: number;
}) {
  const { ticket, status, reason, attention, health, now } = input;

  await getRealtimeDatabase()
    .ref(`nudgeDeliveries/${ticket.eventId}/${ticket.recipientUserId}`)
    .update({
      eventId: ticket.eventId,
      groupId: ticket.groupId,
      kind: ticket.kind,
      senderUserId: ticket.senderUserId,
      recipientUserId: ticket.recipientUserId,
      recipientName: ticket.recipientName,
      status,
      reason: reason ?? null,
      attention: attention ?? null,
      health: health ?? null,
      recordedAt: now
    })
    .catch((error) => {
      logger.warn(
        {
          checkpoint: "NUDGE-DELIVERY-BE-W1",
          category: "expected",
          eventId: ticket.eventId,
          error: describeError(error)
        },
        "failed to persist nudge delivery outcome (non-fatal)"
      );
    });

  await upsertRecipientDeliveryRollup({
    ticket,
    status,
    reason,
    attention,
    health,
    now
  });

  logger.info(
    {
      checkpoint: "NUDGE-DELIVERY-BE-01",
      category: "expected",
      eventId: ticket.eventId,
      kind: ticket.kind,
      recipientUserId: ticket.recipientUserId,
      status,
      reason: reason ?? null,
      attention: attention ?? null,
      health: health ?? null
    },
    "nudge delivery outcome recorded"
  );
}

/**
 * Per-recipient troubleshooting rollup. Lets support/eng answer "which users
 * keep not receiving nudges?" without scanning the full `nudgeDeliveries`
 * tree. Uses an RTDB transaction so concurrent acks across devices can't
 * clobber the counters.
 */
async function upsertRecipientDeliveryRollup(input: {
  ticket: AckTicket;
  status: NudgeDeliveryStatus;
  reason?: string;
  attention?: string;
  health?: Record<string, unknown>;
  now: number;
}) {
  const { ticket, status, reason, attention, health, now } = input;
  try {
    await getRealtimeDatabase()
      .ref(`nudgeDeliveryTroubleshooting/${ticket.recipientUserId}`)
      .transaction((current) => {
        const prev = isRecord(current) ? current : {};
        const played = status === "played";
        const failed = status === "failed";
        const hasAttention = Boolean(attention);
        return {
          recipientUserId: ticket.recipientUserId,
          lastEventId: ticket.eventId,
          lastKind: ticket.kind,
          lastStatus: status,
          lastReason: reason ?? null,
          lastAttention: attention ?? null,
          lastHealth: health ?? null,
          lastRecordedAt: now,
          totalPlayed: toNumber(prev.totalPlayed) + (played ? 1 : 0),
          totalFailed: toNumber(prev.totalFailed) + (failed ? 1 : 0),
          totalAttention: toNumber(prev.totalAttention) + (hasAttention ? 1 : 0),
          consecutiveFailures: failed ? toNumber(prev.consecutiveFailures) + 1 : 0,
          consecutiveAttention: played && hasAttention ? toNumber(prev.consecutiveAttention) + 1 : 0,
          updatedAt: now
        };
      });
  } catch (error) {
    logger.warn(
      {
        checkpoint: "NUDGE-TROUBLESHOOTING-BE-W1",
        category: "expected",
        recipientUserId: ticket.recipientUserId,
        error: describeError(error)
      },
      "failed to upsert recipient delivery rollup (non-fatal)"
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function toNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

async function collectAndroidDevices(userId: string): Promise<string[]> {
  const snapshot = await getRealtimeDatabase().ref(`userDevices/${userId}`).get();
  if (!snapshot.exists()) return [];
  const devices: string[] = [];
  for (const value of Object.values(snapshot.val() as Record<string, unknown>)) {
    if (typeof value !== "object" || value === null) continue;
    const v = value as Record<string, unknown>;
    if (v.deviceState !== "active" || v.platform !== "android") continue;
    const fcmToken = v.fcmToken?.toString().trim();
    if (fcmToken) devices.push(fcmToken);
  }
  return devices;
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function describeError(error: unknown) {
  if (error instanceof Error) {
    return { name: error.name, message: error.message };
  }
  return { name: typeof error, message: String(error) };
}
