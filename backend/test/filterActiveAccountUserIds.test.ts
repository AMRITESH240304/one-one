import assert from "node:assert/strict";
import test from "node:test";

test("filterActiveAccountUserIds keeps only existing active users", async (t) => {
  // Lightweight pure contract: missing users/{uid} == deleted account.
  // Uninstall leaves users/{uid}, so those ids must remain eligible.
  const present = new Map<string, { accountState?: string } | null>([
    ["alive", { accountState: "active" }],
    ["disabled", { accountState: "disabled" }],
    ["deleted_row", null],
    ["no_state", {}]
  ]);

  const filtered = ["alive", "disabled", "deleted_row", "missing", "no_state"].filter(
    (userId) => {
      if (!present.has(userId)) return false;
      const row = present.get(userId);
      if (row == null) return false;
      return (row.accountState ?? "active") === "active";
    }
  );

  assert.deepEqual(filtered, ["alive", "no_state"]);
});
