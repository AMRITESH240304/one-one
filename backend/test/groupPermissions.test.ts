import assert from "node:assert/strict";
import test from "node:test";
import { isVerifiedGroupOwner } from "../src/groups/groupService.js";

test("owner actions require both ownership fields to agree", () => {
  assert.equal(isVerifiedGroupOwner("owner", "owner", "owner"), true);
  assert.equal(isVerifiedGroupOwner("owner", "member", "owner"), false);
  assert.equal(isVerifiedGroupOwner("owner", "owner", "member"), false);
  assert.equal(isVerifiedGroupOwner("owner", "member", "member"), false);
});
