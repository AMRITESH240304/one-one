import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { getRealtimeDatabase } from "../firebase/database.js";
import { sendAndroidDataPushes, sendPushToTokens } from "../firebase/messaging.js";
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

export type NudgeKind = "ring_nudge" | "voice_nudge";

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
    (v.kind === "ring_nudge" || v.kind === "voice_nudge") &&
    typeof v.senderUserId === "string" &&
    typeof v.recipientUserId === "string" &&
    typeof v.recipientName === "string" &&
    typeof v.iat === "number"
  );
}

// ---------------------------------------------------------------------------
// recordNudgeDelivery — called once the receiver's device has genuinely
// started playing the nudge (or definitively failed to). Persists the
// outcome for later debugging and pushes a real-time result back to the
// sender so they see accurate delivery confirmation, not just "sent".
// ---------------------------------------------------------------------------

export type NudgeDeliveryStatus = "played" | "failed";

// B7: "high" / "medium" / "low" ambient noise reading sampled by the
// receiver's device for ~10s after the nudge finished playing. Arrives as
// its own follow-up ack (same eventId/status="played") once sampling
// completes, separate from the initial played/failed ack.
export type AmbientNoiseLevel = "high" | "medium" | "low";

export type RecordNudgeDeliveryInput = {
  ticket: AckTicket;
  status: NudgeDeliveryStatus;
  reason?: string;
  health?: Record<string, unknown>;
  ambientNoiseLevel?: AmbientNoiseLevel;
};

export async function recordNudgeDelivery(input: RecordNudgeDeliveryInput) {
  const { ticket, status, reason, health, ambientNoiseLevel } = input;
  const now = nowSeconds();

  // Best-effort audit trail — never blocks the ack or the sender push.
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
      health: health ?? null,
      ...(ambientNoiseLevel ? { ambientNoiseLevel } : {}),
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

  logger.info(
    {
      checkpoint: "NUDGE-DELIVERY-BE-01",
      category: "expected",
      eventId: ticket.eventId,
      kind: ticket.kind,
      recipientUserId: ticket.recipientUserId,
      status,
      reason: reason ?? null,
      health: health ?? null,
      ambientNoiseLevel: ambientNoiseLevel ?? null
    },
    "nudge delivery outcome recorded"
  );

  const senderDevices = await collectAndroidDevices(ticket.senderUserId);
  if (senderDevices.length === 0) {
    return { eventId: ticket.eventId, status, reason: reason ?? null, notifiedSenderDevices: 0 };
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
        ambientNoiseLevel: ambientNoiseLevel ?? ""
      }
    })),
    30 * 1000
  );

  // Only a genuinely loud environment is worth surfacing as a real OS
  // notification — quiet/moderate readings are just informational data the
  // sheet can show inline while it's still open, not worth interrupting for.
  if (status === "played" && ambientNoiseLevel === "high") {
    await sendPushToTokens({
      tokens: senderDevices,
      title: "It sounds noisy over there \u{1F50A}",
      body: `${ticket.recipientName} may not have heard your nudge clearly \u2014 it's loud around them right now.`,
      data: {
        type: "nudge_ambient_noise",
        eventId: ticket.eventId,
        groupId: ticket.groupId,
        kind: ticket.kind,
        recipientUserId: ticket.recipientUserId,
        recipientName: ticket.recipientName,
        status,
        ambientNoiseLevel
      }
    }).catch((error) => {
      logger.warn(
        {
          checkpoint: "NUDGE-DELIVERY-BE-W2",
          category: "expected",
          eventId: ticket.eventId,
          error: describeError(error)
        },
        "failed to send ambient-noise notification to sender (non-fatal)"
      );
    });
  }

  return {
    eventId: ticket.eventId,
    status,
    reason: reason ?? null,
    ambientNoiseLevel: ambientNoiseLevel ?? null,
    notifiedSenderDevices: senderDevices.length,
    sent: pushResult.successCount
  };
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
