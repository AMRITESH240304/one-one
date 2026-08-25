/**
 * Collapsing chat-pile unread state. Must stay aligned with the Flutter
 * bubble window: `ChatMessageRepository.visibleLimit` (5) and
 * lifetime + fade (10 + 2 minutes).
 */
export const chatUnreadMax = 5;
export const chatUnreadTtlSeconds = 12 * 60;

export type ChatUnreadRecord = {
  count: number;
  updatedAt: number;
};

/**
 * Next unread pile after a newly delivered chat message.
 *
 * - Missing / zero `updatedAt` is treated as stale so leftover counts from
 *   before this field existed (or after bubbles have vanished) restart at 1.
 * - A gap of [chatUnreadTtlSeconds] since the last bump also restarts at 1,
 *   matching the 12-minute bubble lifetime + fade.
 * - The visible feed only keeps 5 bubbles, so the pile never reports more.
 */
export function nextChatUnread(
  current: unknown,
  nowSeconds: number,
  max = chatUnreadMax,
  ttlSeconds = chatUnreadTtlSeconds
): ChatUnreadRecord {
  const record = isRecord(current) ? current : {};
  const prevCount = typeof record.count === "number" ? record.count : 0;
  const prevUpdatedAt = typeof record.updatedAt === "number" ? record.updatedAt : 0;
  const stale = prevUpdatedAt <= 0 || nowSeconds - prevUpdatedAt >= ttlSeconds;
  const base = stale || prevCount <= 0 ? 0 : prevCount;
  return {
    count: Math.min(base + 1, max),
    updatedAt: nowSeconds
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
