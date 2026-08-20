import assert from "node:assert/strict";
import test from "node:test";
import {
  buildDeviceLogStoragePath,
  isOwnedDeviceLogPath,
  sanitizeMetadataValue
} from "../src/deviceLogs/deviceLogService.js";

test("device log storage path is namespaced by kind and user", () => {
  const path = buildDeviceLogStoragePath({
    kind: "crash",
    userId: "user-1",
    reportId: "rep-9",
    timestamp: "2026-08-20T01:02:03.004Z"
  });
  assert.equal(
    path,
    "deviceLogs/crash/user-1/2026-08-20T01-02-03-004Z_rep-9.zip"
  );
  assert.equal(isOwnedDeviceLogPath(path, "user-1"), true);
  assert.equal(isOwnedDeviceLogPath(path, "user-2"), false);
  assert.equal(isOwnedDeviceLogPath("voiceNudges/abc.m4a", "user-1"), false);
});

test("metadata values are trimmed and bounded", () => {
  assert.equal(sanitizeMetadataValue("  Pixel 8  "), "Pixel 8");
  assert.equal(sanitizeMetadataValue(""), "-");
  assert.equal(sanitizeMetadataValue("x".repeat(300)).length, 256);
  assert.equal(sanitizeMetadataValue(undefined, ""), "");
});
