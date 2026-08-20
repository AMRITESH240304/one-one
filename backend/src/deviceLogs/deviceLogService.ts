import { randomUUID } from "node:crypto";
import { HttpError } from "../http/httpError.js";
import {
  createSignedWriteUrl,
  getAppBucket
} from "../firebase/storage.js";

export const deviceLogUploadContentType = "application/zip";
export const maxDeviceLogBytes = 8 * 1024 * 1024;
const deviceLogUploadUrlTtlMs = 5 * 60 * 1000;

export type DeviceLogKind = "crash" | "feedback";

export type DeviceLogMetadata = {
  userId: string;
  groupId: string;
  appVersion: string;
  deviceModel: string;
  androidVersion: string;
  timestamp: string;
  kind: DeviceLogKind;
  description: string;
};

const kindPattern = /^(crash|feedback)$/;
const safeToken = /^[A-Za-z0-9._-]{1,128}$/;

export function sanitizeMetadataValue(value: unknown, fallback = "-") {
  const raw = typeof value === "string" ? value.trim() : "";
  if (!raw) return fallback;
  return raw.slice(0, 256);
}

export function buildDeviceLogStoragePath(input: {
  kind: DeviceLogKind;
  userId: string;
  reportId: string;
  timestamp: string;
}) {
  const stamp = input.timestamp.replace(/[:.]/g, "-");
  return `deviceLogs/${input.kind}/${input.userId}/${stamp}_${input.reportId}.zip`;
}

export function isOwnedDeviceLogPath(storagePath: string, userId: string) {
  if (!safeToken.test(userId)) return false;
  const match = storagePath.match(
    /^deviceLogs\/(crash|feedback)\/([^/]+)\/[^/]+\.zip$/
  );
  return Boolean(match && match[2] === userId);
}

export async function initiateDeviceLogUpload(input: {
  userId: string;
  kind: DeviceLogKind;
  groupId?: string;
  appVersion?: string;
  deviceModel?: string;
  androidVersion?: string;
  description?: string;
}) {
  if (!kindPattern.test(input.kind)) {
    throw new HttpError(400, "invalid_device_log_kind", "kind must be crash or feedback.");
  }
  if (!safeToken.test(input.userId)) {
    throw new HttpError(400, "invalid_user_id", "Authenticated user id is invalid.");
  }

  const timestamp = new Date().toISOString();
  const reportId = randomUUID();
  const metadata: DeviceLogMetadata = {
    userId: input.userId,
    groupId: sanitizeMetadataValue(input.groupId),
    appVersion: sanitizeMetadataValue(input.appVersion),
    deviceModel: sanitizeMetadataValue(input.deviceModel),
    androidVersion: sanitizeMetadataValue(input.androidVersion),
    timestamp,
    kind: input.kind,
    description: sanitizeMetadataValue(input.description, "")
  };
  const storagePath = buildDeviceLogStoragePath({
    kind: input.kind,
    userId: input.userId,
    reportId,
    timestamp
  });
  const signed = await createSignedWriteUrl({
    storagePath,
    contentType: deviceLogUploadContentType,
    expiresAtMs: Date.now() + deviceLogUploadUrlTtlMs,
    maxBytes: maxDeviceLogBytes
  });

  return {
    reportId,
    storagePath,
    maxBytes: maxDeviceLogBytes,
    metadata,
    ...signed
  };
}

export async function completeDeviceLogUpload(input: {
  userId: string;
  storagePath: string;
  metadata: DeviceLogMetadata;
}) {
  if (!isOwnedDeviceLogPath(input.storagePath, input.userId)) {
    throw new HttpError(
      403,
      "device_log_path_forbidden",
      "That log report path does not belong to this user."
    );
  }
  if (input.metadata.userId !== input.userId) {
    throw new HttpError(403, "device_log_user_mismatch", "Report user does not match the signed-in user.");
  }

  const file = getAppBucket().file(input.storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    throw new HttpError(404, "device_log_missing", "No log archive was uploaded.");
  }

  const [gcsMetadata] = await file.getMetadata();
  const size = Number(gcsMetadata.size ?? 0);
  if (!Number.isFinite(size) || size < 4 || size > maxDeviceLogBytes) {
    await file.delete({ ignoreNotFound: true }).catch(() => undefined);
    throw new HttpError(413, "device_log_invalid_size", "Uploaded log archive is empty or too large.");
  }

  const [header] = await file.download({ start: 0, end: 1 });
  if (header.length < 2 || header.subarray(0, 2).toString("binary") !== "PK") {
    await file.delete({ ignoreNotFound: true }).catch(() => undefined);
    throw new HttpError(400, "device_log_invalid_archive", "Uploaded file is not a zip archive.");
  }

  await file.setMetadata({
    contentType: deviceLogUploadContentType,
    metadata: {
      userId: input.metadata.userId,
      groupId: input.metadata.groupId,
      appVersion: input.metadata.appVersion,
      deviceModel: input.metadata.deviceModel,
      androidVersion: input.metadata.androidVersion,
      timestamp: input.metadata.timestamp,
      kind: input.metadata.kind,
      description: input.metadata.description
    }
  });

  return {
    storagePath: input.storagePath,
    sizeBytes: size
  };
}
