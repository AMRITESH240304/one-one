import { AccessToken, RoomServiceClient, type VideoGrant } from "livekit-server-sdk";
import { config, liveKitConfigured } from "../config.js";
import { HttpError } from "../http/httpError.js";

export type LiveKitTokenInput = {
  roomName: string;
  participantIdentity: string;
  participantName?: string;
  canPublish?: boolean;
  canSubscribe?: boolean;
  canPublishData?: boolean;
  ttl?: string | number;
};

export async function createLiveKitToken(input: LiveKitTokenInput) {
  if (!liveKitConfigured) {
    throw new HttpError(
      503,
      "livekit_not_configured",
      "LiveKit is not configured. Set LIVEKIT_URL, LIVEKIT_API_KEY, and LIVEKIT_API_SECRET."
    );
  }

  const accessToken = new AccessToken(config.LIVEKIT_API_KEY!, config.LIVEKIT_API_SECRET!, {
    identity: input.participantIdentity,
    name: input.participantName,
    ttl: input.ttl ?? "1h"
  });

  const grant: VideoGrant = {
    roomJoin: true,
    room: input.roomName,
    canPublish: input.canPublish ?? true,
    canSubscribe: input.canSubscribe ?? true,
    canPublishData: input.canPublishData ?? true
  };

  accessToken.addGrant(grant);

  return {
    url: config.LIVEKIT_URL!,
    token: await accessToken.toJwt(),
    roomName: input.roomName,
    participantIdentity: input.participantIdentity
  };
}

export function createLiveKitRoomServiceClient() {
  if (!liveKitConfigured) return null;
  const host = config.LIVEKIT_URL!.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
  return new RoomServiceClient(host, config.LIVEKIT_API_KEY!, config.LIVEKIT_API_SECRET!);
}

export function isLiveKitNotFound(error: unknown) {
  if (typeof error !== "object" || error === null) return false;
  const record = error as Record<string, unknown>;
  const status = record.status ?? record.code;
  return status === 404 || status === "not_found";
}
