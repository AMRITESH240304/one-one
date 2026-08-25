import assert from "node:assert/strict";
import test from "node:test";
import {
  chatUnreadMax,
  chatUnreadTtlSeconds,
  nextChatUnread
} from "../src/notifications/chatUnread.js";

test("first chat unread bump starts at 1", () => {
  assert.deepEqual(nextChatUnread(null, 1_000), { count: 1, updatedAt: 1_000 });
});

test("consecutive bumps within the bubble lifetime increment", () => {
  const first = nextChatUnread(null, 1_000);
  const second = nextChatUnread(first, 1_000 + 60);
  assert.equal(second.count, 2);
  const third = nextChatUnread(second, 1_000 + 120);
  assert.equal(third.count, 3);
});

test("unread pile caps at the visible bubble window", () => {
  let current: unknown = null;
  let now = 1_000;
  for (let i = 0; i < chatUnreadMax + 8; i += 1) {
    current = nextChatUnread(current, now);
    now += 10;
  }
  assert.equal((current as { count: number }).count, chatUnreadMax);
});

test("stale piles restart at 1 after bubbles have vanished", () => {
  const piled = { count: 25, updatedAt: 1_000 };
  const next = nextChatUnread(piled, 1_000 + chatUnreadTtlSeconds);
  assert.equal(next.count, 1);
});

test("legacy rows without updatedAt restart at 1", () => {
  const next = nextChatUnread({ count: 25 }, 1_000);
  assert.equal(next.count, 1);
});

test("a cleared pile (count 0) starts the next notification at 1", () => {
  const next = nextChatUnread({ count: 0, updatedAt: 1_000 }, 1_060);
  assert.equal(next.count, 1);
});
