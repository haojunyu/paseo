/**
 * Timeline core — ported from packages/app/src/timeline/session-stream-reducers.ts
 * and packages/app/src/types/stream.ts.
 *
 * Handles:
 * 1. Converting raw daemon timeline entries into StreamItem[] arrays
 * 2. Sequence-number-based deduplication and gap detection
 * 3. Merging incremental timeline pages (tail, before, after)
 *
 * Phase 1 scope: the happy path for a single agent's timeline.
 * Edge cases (epoch changes, reset, assistant head preservation, optimistic
 * user merge) are simplified. Full parity with the RN implementation is a
 * Phase 2 task.
 */

import type {
  StreamItem,
  TimelineCursor,
  TimelineEvent,
  TimelineEventItem,
  UserMessageItem,
  AssistantMessageItem,
  ThoughtItem,
  ToolCallItem,
  ActivityLogItem,
  AgentToolCallStatus,
} from './stream-types';
import { generateStreamId } from './stream-types';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Maximum number of items to keep in the live head buffer. */
const MAX_HEAD_SIZE = 200;

// ---------------------------------------------------------------------------
// Stream reduction: raw events → StreamItem[]
// ---------------------------------------------------------------------------

/**
 * Append a live stream event to the items array.
 * Mutates `items` in place and returns the same reference for chaining.
 */
function appendStreamItem(items: StreamItem[], item: StreamItem): StreamItem[] {
  items.push(item);
  return items;
}

function buildUserMessage(item: TimelineEventItem, timestamp: number): UserMessageItem {
  return {
    kind: 'user_message',
    id: generateStreamId('user'),
    text: item.text ?? '',
    timestamp,
  };
}

function buildAssistantMessage(item: TimelineEventItem, timestamp: number): AssistantMessageItem {
  return {
    kind: 'assistant_message',
    id: item.messageId ?? generateStreamId('assistant'),
    text: item.text ?? '',
    timestamp,
  };
}

function buildThought(item: TimelineEventItem, timestamp: number): ThoughtItem {
  return {
    kind: 'thought',
    id: generateStreamId('thought'),
    text: item.text ?? '',
    timestamp,
    status: 'ready',
  };
}

function buildToolCall(item: TimelineEventItem, timestamp: number): ToolCallItem {
  return {
    kind: 'tool_call',
    id: generateStreamId('tool'),
    timestamp,
    callId: item.callId ?? 'unknown',
    provider: '',  // Filled by caller
    name: item.name ?? 'unknown',
    status: (item.status as AgentToolCallStatus) ?? 'running',
    detail: item.detail ?? {},
  };
}

function buildActivityLog(item: TimelineEventItem, timestamp: number): ActivityLogItem {
  return {
    kind: 'activity_log',
    id: generateStreamId('activity'),
    timestamp,
    activityType: (item.status === 'failed' ? 'error' : 'info') as ActivityLogType,
    message: item.message ?? item.text ?? '',
  };
}

function mergeAssistantText(existing: StreamItem[], text: string, timestamp: number): StreamItem[] {
  const last = existing[existing.length - 1];
  if (last && last.kind === 'assistant_message') {
    const updated: AssistantMessageItem = {
      ...last,
      text: last.text + text,
      timestamp,
    };
    const next = [...existing];
    next[next.length - 1] = updated;
    return next;
  }
  return existing;
}

/**
 * Apply a single timeline event to the stream state.
 * Ported from `reduceStreamUpdate` in types/stream.ts.
 */
export function reduceStreamUpdate(
  state: StreamItem[],
  event: TimelineEvent,
  timestamp: number,
): StreamItem[] {
  const item = event.item;

  switch (item.type) {
    case 'user_message':
      return appendStreamItem([...state], buildUserMessage(item, timestamp));

    case 'assistant_message': {
      // Merge contiguous assistant text chunks
      const last = state[state.length - 1];
      if (last && last.kind === 'assistant_message') {
        return mergeAssistantText(state, item.text ?? '', timestamp);
      }
      return appendStreamItem([...state], buildAssistantMessage(item, timestamp));
    }

    case 'reasoning':
      return appendStreamItem([...state], buildThought(item, timestamp));

    case 'tool_call': {
      // Update existing tool call if callId matches
      if (item.callId) {
        const existingIdx = state.findLastIndex(
          (s) => s.kind === 'tool_call' && (s as ToolCallItem).callId === item.callId
        );
        if (existingIdx >= 0) {
          const next = [...state];
          const existing = next[existingIdx] as ToolCallItem;
          next[existingIdx] = {
            ...existing,
            status: (item.status as AgentToolCallStatus) ?? existing.status,
            detail: item.detail ?? existing.detail,
            timestamp,
          };
          return next;
        }
      }
      const tc = buildToolCall(item, timestamp);
      tc.provider = event.provider;
      const next = [...state];
      next.push(tc);
      return next;
    }

    case 'error':
      return appendStreamItem([...state], buildActivityLog(item, timestamp));

    case 'turn':
      // Turn boundaries are ignored in Phase 1 (visual only separator)
      return state;

    default:
      return state;
  }
}

/**
 * Hydrate an array of raw timeline entries into StreamItem[].
 * This is the equivalent of `hydrateStreamState` in the RN code.
 */
export function hydrateStreamState(
  events: Array<{ event: TimelineEvent; timestamp: number }>,
): StreamItem[] {
  let state: StreamItem[] = [];
  for (const { event, timestamp } of events) {
    state = reduceStreamUpdate(state, event, timestamp);
  }
  return state;
}

// ---------------------------------------------------------------------------
// Timeline response processing (simplified)
// ---------------------------------------------------------------------------

export interface TimelineResponsePayload {
  agentId: string;
  direction: 'tail' | 'before' | 'after';
  reset: boolean;
  epoch: string;
  startSeq: number | null;
  endSeq: number | null;
  entries: TimelineResponseEntry[];
  error: string | null;
  hasNewer: boolean;
  hasOlder: boolean;
}

export interface TimelineResponseEntry {
  seqStart: number;
  seqEnd: number;
  provider: string;
  item: Record<string, unknown>;
  timestamp: string; // ISO 8601
}

export interface ProcessTimelineInput {
  payload: TimelineResponsePayload;
  currentTail: StreamItem[];
  currentHead: StreamItem[];
  currentCursor: TimelineCursor | undefined;
}

export interface ProcessTimelineOutput {
  tail: StreamItem[];
  head: StreamItem[];
  cursor: TimelineCursor | undefined;
  cursorChanged: boolean;
  error: string | null;
  /** True if there are more items to fetch (for pagination). */
  hasMore: boolean;
}

/**
 * Determine if a timeline entry should be accepted based on sequence numbers.
 */
function shouldAcceptSeq(
  cursor: TimelineCursor | undefined,
  epoch: string,
  seq: number,
): 'accept' | 'drop' | 'gap' {
  if (!cursor) {
    return 'accept';
  }
  if (cursor.epoch !== epoch) {
    return 'drop';
  }
  if (seq <= cursor.endSeq) {
    return 'drop';
  }
  if (seq > cursor.endSeq + 1) {
    return 'gap';
  }
  return 'accept';
}

/**
 * Process a timeline response from the daemon.
 *
 * Simplified port of `processTimelineResponse` from session-stream-reducers.ts.
 * Phase 1 handles the common paths:
 *   - Initial tail load (direction='tail', no cursor)
 *   - Live stream append (direction='after', sequential seqs)
 *   - Error payloads
 *
 * Not yet implemented (Phase 2):
 *   - Direction 'before' (scrollback pagination)
 *   - Epoch changes / reset paths
 *   - Optimistic user message reconciliation
 *   - Assistant head preservation on replace
 */
export function processTimelineResponse(input: ProcessTimelineInput): ProcessTimelineOutput {
  const { payload, currentTail, currentHead, currentCursor } = input;

  // Error path
  if (payload.error) {
    return {
      tail: currentTail,
      head: currentHead,
      cursor: currentCursor,
      cursorChanged: false,
      error: payload.error,
      hasMore: false,
    };
  }

  // No entries — nothing to do
  if (!payload.entries || payload.entries.length === 0) {
    return {
      tail: currentTail,
      head: currentHead,
      cursor: currentCursor,
      cursorChanged: false,
      error: null,
      hasMore: false,
    };
  }

  // Convert entries to { event, timestamp } pairs
  const hydrated = payload.entries.map((entry) => ({
    event: {
      provider: entry.provider,
      item: entry.item as TimelineEventItem,
    } as TimelineEvent,
    timestamp: new Date(entry.timestamp).getTime(),
    seq: entry.seqStart,
  }));

  // ----------------------------------------------------------------
  // Case 1: Initial load (no cursor) or reset
  // Replace tail entirely
  // ----------------------------------------------------------------
  if (!currentCursor || payload.reset) {
    const newTail = hydrateStreamState(hydrated);
    const newCursor: TimelineCursor = {
      epoch: payload.epoch,
      startSeq: payload.startSeq ?? hydrated[0]?.seq ?? 1,
      endSeq: payload.endSeq ?? hydrated[hydrated.length - 1]?.seq ?? 1,
    };

    return {
      tail: newTail,
      head: [],
      cursor: newCursor,
      cursorChanged: true,
      error: null,
      hasMore: payload.hasNewer,
    };
  }

  // ----------------------------------------------------------------
  // Case 2: Incremental append (direction='after' or 'tail' with cursor)
  // Filter stale events, detect gaps, append new items
  // ----------------------------------------------------------------
  let nextTail = [...currentTail];
  let nextHead = [...currentHead];
  let nextCursor: TimelineCursor = { ...currentCursor };
  let acceptedCount = 0;
  let hasGap = false;

  for (const entry of hydrated) {
    const decision = shouldAcceptSeq(nextCursor, payload.epoch, entry.seq);

    switch (decision) {
      case 'accept': {
        // Apply to head if it has items, otherwise to tail
        if (nextHead.length > 0) {
          nextHead = reduceStreamUpdate(nextHead, entry.event, entry.timestamp);
        } else {
          nextTail = reduceStreamUpdate(nextTail, entry.event, entry.timestamp);
        }
        nextCursor.endSeq = entry.seq;
        acceptedCount += 1;
        break;
      }
      case 'gap': {
        hasGap = true;
        // Accept the event anyway to avoid dropping data, but mark the gap
        if (nextHead.length > 0) {
          nextHead = reduceStreamUpdate(nextHead, entry.event, entry.timestamp);
        } else {
          nextTail = reduceStreamUpdate(nextTail, entry.event, entry.timestamp);
        }
        nextCursor.endSeq = entry.seq;
        acceptedCount += 1;
        break;
      }
      case 'drop':
        // Silently drop duplicates
        break;
    }
  }

  // Trim head to max size
  if (nextHead.length > MAX_HEAD_SIZE) {
    // Move oldest head items to tail
    const overflow = nextHead.length - MAX_HEAD_SIZE;
    nextTail = [...nextTail, ...nextHead.slice(0, overflow)];
    nextHead = nextHead.slice(overflow);
  }

  const cursorChanged = acceptedCount > 0;

  return {
    tail: nextTail,
    head: nextHead,
    cursor: nextCursor,
    cursorChanged,
    error: hasGap ? null : null, // Gap is informational, not an error
    hasMore: payload.hasNewer,
  };
}
