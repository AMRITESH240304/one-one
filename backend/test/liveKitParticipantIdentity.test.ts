import assert from "node:assert/strict";
import test from "node:test";
import { userIdFromGroupParticipantIdentity } from "../src/livekit/liveKitTokenService.js";

test("accepts only participant identities from the requested LiveKit group", () => {
  assert.equal(userIdFromGroupParticipantIdentity("group-1", "group-1:user-2:device-3"), "user-2");
  assert.equal(userIdFromGroupParticipantIdentity("group-1", "group-2:user-2:device-3"), null);
  assert.equal(userIdFromGroupParticipantIdentity("group-1", "group-1:user-2"), null);
});
