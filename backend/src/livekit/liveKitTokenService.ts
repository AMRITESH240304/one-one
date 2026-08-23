import { getRealtimeDatabase } from "../firebase/database.js";
import {
  requireActiveGroup,
  requireActiveGroupMember,
  requireActiveUser,
  requireActiveUserDevice
} from "../groups/groupService.js";
import { HttpError } from "../http/httpError.js";
import { createLiveKitToken } from "./tokens.js";

const tokenTtlSeconds = 60 * 60;

export type IssueGroupLiveKitTokenInput = {
  userId: string;
  groupId: string;
  deviceId: string;
  serviceSessionId: string;
  livekitSessionId: string;
};

export async function issueGroupLiveKitToken(input: IssueGroupLiveKitTokenInput) {
  const db = getRealtimeDatabase();

  await requireActiveUser(input.userId);
  const group = await requireActiveGroup(input.groupId);
  await requireActiveGroupMember(input.groupId, input.userId);
  await requireActiveUserDevice(input.userId, input.deviceId);

  const roomName = await requireActiveLiveKitRoomName(input.groupId, group.livekitRoomName);
  const participantIdentity = `${input.groupId}:${input.userId}:${input.deviceId}`;
  const participantName =
    (await db.ref(`users/${input.userId}/displayName`).get()).val()?.toString() ||
    input.userId;
  const now = nowSeconds();
  const expiresAt = now + tokenTtlSeconds;
  const tokenResponse = await createLiveKitToken({
    roomName,
    participantIdentity,
    participantName,
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
    ttl: tokenTtlSeconds
  });

  const issuanceRef = db.ref("livekitTokenIssuances").push();
  const tokenId = issuanceRef.key;

  if (!tokenId) {
    throw new HttpError(500, "token_issuance_id_failed", "Failed to allocate token issuance id.");
  }

  await issuanceRef.set({
    tokenId,
    groupId: input.groupId,
    userId: input.userId,
    deviceId: input.deviceId,
    serviceSessionId: input.serviceSessionId,
    livekitSessionId: input.livekitSessionId,
    participantIdentity,
    roomName,
    issuedAt: now,
    expiresAt,
    revokedAt: null
  });

  return {
    serverUrl: tokenResponse.url,
    roomName,
    participantIdentity,
    participantName,
    token: tokenResponse.token,
    expiresAt
  };
}

async function requireActiveLiveKitRoomName(groupId: string, fallback: string) {
  const snapshot = await getRealtimeDatabase().ref(`livekitRooms/${groupId}`).get();
  if (!snapshot.exists()) {
    throw new HttpError(404, "livekit_room_not_found", "LiveKit room mapping does not exist.");
  }
  if ((snapshot.child("roomState").val() ?? "active") !== "active") {
    throw new HttpError(409, "livekit_room_not_active", "LiveKit room mapping is not active.");
  }
  return snapshot.child("roomName").val()?.toString() || fallback;
}

export function userIdFromGroupParticipantIdentity(groupId: string, identity: string) {
  const [identityGroupId, participantUserId, deviceId] = identity.split(":");
  return identityGroupId === groupId && participantUserId && deviceId ? participantUserId : null;
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}
