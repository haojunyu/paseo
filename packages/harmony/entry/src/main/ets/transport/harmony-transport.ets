/**
 * HarmonyOS WebSocket transport adapter for Paseo DaemonClient.
 *
 * Implements the `DaemonTransport` interface (from @getpaseo/client) using
 * @ohos.net.webSocket. Handles both JSON text frames (session messages) and
 * binary frames (terminal I/O).
 *
 * Paseo binary frame layout (2-byte header + payload):
 *   byte 0: opcode  (0x01 = Output, 0x02 = Input, 0x03 = Resize, 0x04 = Snapshot)
 *   byte 1: slot    (terminal slot id)
 *   rest:   payload (raw bytes or JSON)
 *
 * @module harmony-transport
 */

import webSocket from '@ohos.net.webSocket';
import type { DaemonTransport, TransportLogger } from '@getpaseo/client/internal/daemon-client-transport-types';

/** ReadyState constants matching the standard WebSocket spec. */
const WS_CONNECTING = 0;
const WS_OPEN = 1;
const WS_CLOSING = 2;
const WS_CLOSED = 3;

export interface HarmonyTransportOptions {
  url: string;
  /** Optional headers sent during the WebSocket handshake. */
  headers?: Record<string, string>;
  /** Optional sub-protocols. */
  protocols?: string[];
  /** Logger for transport-level diagnostics. */
  logger?: TransportLogger;
}

/**
 * Creates a DaemonTransport backed by @ohos.net.webSocket.
 *
 * Usage:
 * ```typescript
 * import { createHarmonyTransport } from '../transport/harmony-transport';
 * import { DaemonClient } from '@getpaseo/client';
 *
 * const transport = createHarmonyTransport({ url: 'ws://192.168.1.5:6767' });
 * const client = new DaemonClient({ transportFactory: () => transport });
 * ```
 */
export function createHarmonyTransport(options: HarmonyTransportOptions): DaemonTransport {
  const { url, headers, protocols, logger } = options;

  const ws = webSocket.createWebSocket();
  const messageHandlers: Array<(data: unknown) => void> = [];
  const openHandlers: Array<() => void> = [];
  const closeHandlers: Array<(event?: unknown) => void> = [];
  const errorHandlers: Array<(event?: unknown) => void> = [];

  // ---------------------------------------------------------------------------
  // Connection setup
  // ---------------------------------------------------------------------------

  const connectOptions: webSocket.WebSocketRequestOptions = {
    header: headers ?? {},
  };

  if (protocols && protocols.length > 0) {
    connectOptions.header['Sec-WebSocket-Protocol'] = protocols.join(', ');
  }

  ws.connect(url, connectOptions, (err: Error | null) => {
    if (err) {
      logger?.warn({ err: err.message, url }, 'HarmonyTransport: connect failed');
      for (const handler of errorHandlers) {
        handler({ message: err.message });
      }
      return;
    }

    logger?.warn({ url }, 'HarmonyTransport: connected');

    // -----------------------------------------------------------------------
    // Message handler — routes JSON and binary frames
    // -----------------------------------------------------------------------
    ws.on('message', (err: Error | null, value: string | ArrayBuffer) => {
      if (err) {
        logger?.warn({ err: err.message }, 'HarmonyTransport: message error');
        return;
      }

      // The daemon sends two kinds of data:
      // 1. JSON text frames → passed as string (session messages, ping/pong)
      // 2. Binary frames → passed as ArrayBuffer (terminal I/O)
      // In both cases, DaemonClient expects the raw value.
      for (const handler of messageHandlers) {
        handler(value);
      }
    });

    // -----------------------------------------------------------------------
    // Close handler
    // -----------------------------------------------------------------------
    ws.on('close', (err: Error | null, value: webSocket.CloseResult) => {
      logger?.warn({
        code: value.code,
        reason: value.reason,
        err: err?.message,
      }, 'HarmonyTransport: closed');
      for (const handler of closeHandlers) {
        handler({ code: value.code, reason: value.reason });
      }
    });

    // -----------------------------------------------------------------------
    // Error handler
    // -----------------------------------------------------------------------
    ws.on('error', (err: Error) => {
      logger?.warn({ err: err.message }, 'HarmonyTransport: error');
      for (const handler of errorHandlers) {
        handler({ message: err.message });
      }
    });

    // -----------------------------------------------------------------------
    // Fire open handlers
    // -----------------------------------------------------------------------
    for (const handler of openHandlers) {
      handler();
    }
  });

  // ---------------------------------------------------------------------------
  // DaemonTransport interface
  // ---------------------------------------------------------------------------

  return {
    send(data: string | Uint8Array | ArrayBuffer): void {
      ws.send(data);
    },

    close(code?: number, reason?: string): void {
      ws.close({
        code: code ?? 1000,
        reason: reason ?? '',
      });
    },

    onMessage(handler: (data: unknown) => void): () => void {
      messageHandlers.push(handler);
      return () => {
        const idx = messageHandlers.indexOf(handler);
        if (idx !== -1) {
          messageHandlers.splice(idx, 1);
        }
      };
    },

    onOpen(handler: () => void): () => void {
      openHandlers.push(handler);
      return () => {
        const idx = openHandlers.indexOf(handler);
        if (idx !== -1) {
          openHandlers.splice(idx, 1);
        }
      };
    },

    onClose(handler: (event?: unknown) => void): () => void {
      closeHandlers.push(handler);
      return () => {
        const idx = closeHandlers.indexOf(handler);
        if (idx !== -1) {
          closeHandlers.splice(idx, 1);
        }
      };
    },

    onError(handler: (event?: unknown) => void): () => void {
      errorHandlers.push(handler);
      return () => {
        const idx = errorHandlers.indexOf(handler);
        if (idx !== -1) {
          errorHandlers.splice(idx, 1);
        }
      };
    },
  };
}

/**
 * Decode a Paseo terminal binary frame.
 *
 * Frame layout:
 *   byte 0: opcode
 *   byte 1: slot id
 *   bytes 2+: payload (binary or UTF-8 JSON)
 */
export enum TerminalOpcode {
  Output = 0x01,
  Input = 0x02,
  Resize = 0x03,
  Snapshot = 0x04,
}

export interface TerminalFrame {
  opcode: TerminalOpcode;
  slot: number;
  payload: Uint8Array;
}

export function decodeTerminalFrame(data: ArrayBuffer): TerminalFrame | null {
  if (data.byteLength < 2) {
    return null;
  }

  const bytes = new Uint8Array(data);
  return {
    opcode: bytes[0] as TerminalOpcode,
    slot: bytes[1],
    payload: bytes.slice(2),
  };
}
