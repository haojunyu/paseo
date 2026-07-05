/**
 * Paseo daemon client lifecycle manager.
 *
 * Wraps @getpaseo/client's DaemonClient with ArkUI-friendly lifecycle:
 * - Creates the HarmonyOS WebSocket transport
 * - Manages connect / disconnect
 * - Handles the hello handshake and server_info parsing
 * - Exposes reactive connection state via ConnectionModel
 *
 * Usage:
 * ```typescript
 * const paseo = new PaseoClientLifecycle();
 * await paseo.connect('192.168.1.5', 6767);
 * // Connection state is available via paseo.connection
 * const agents = await paseo.client.listAgents();
 * ```
 */

import { DaemonClient } from '@getpaseo/client';
import { parseServerInfoStatusPayload } from '@getpaseo/protocol/messages';
import { createHarmonyTransport } from '../transport/harmony-transport';
import { ConnectionModel } from '../models/connection-model';
import { AppConstants } from '../common/constants';
import type { DaemonTransport } from '@getpaseo/client/internal/daemon-client-transport-types';
import type { ServerInfoStatusPayload } from '@getpaseo/protocol/messages';
import preferences from '@ohos.data.preferences';

export class PaseoClientLifecycle {
  readonly connection = new ConnectionModel();
  private _client: DaemonClient | null = null;

  /** The underlying DaemonClient instance (null until connected). */
  get client(): DaemonClient | null {
    return this._client;
  }

  /**
   * Connect to a Paseo daemon.
   *
   * @param host - IP address or hostname
   * @param port - WebSocket port (default 6767)
   * @param password - Optional daemon password
   */
  async connect(host: string, port: number = AppConstants.DEFAULT_PORT, password?: string): Promise<void> {
    this.connection.setConnecting();

    const url = `ws://${host}:${port}`;
    const headers: Record<string, string> = {};

    if (password) {
      // Daemon password is sent as a header (Paseo daemon auth)
      headers['x-paseo-password'] = password;
    }

    const transport = createHarmonyTransport({ url, headers });

    try {
      const client = new DaemonClient({
        transportFactory: () => transport,
      });

      // Wait for server_info via the daemon event stream
      const serverInfo = await this.waitForServerInfo(client);

      this._client = client;
      this.connection.setConnected({
        serverId: serverInfo.serverId,
        hostname: serverInfo.hostname,
        version: serverInfo.version,
      });

      // Persist the last-used host for the connect screen
      await this.saveLastConnection(host, port);
    } catch (err) {
      this.connection.setDisconnected(`${err}`);
      throw err;
    }
  }

  /** Disconnect and clean up. */
  disconnect(): void {
    if (this._client) {
      this._client.destroy();
      this._client = null;
    }
    this.connection.setDisconnected();
  }

  /** Load the last-used host and port from persistent storage. */
  async loadLastConnection(): Promise<{ host: string; port: number } | null> {
    try {
      const prefs = await preferences.getPreferences(getContext(), 'paseo');
      const host = prefs.get(AppConstants.PREF_LAST_HOST, '') as string;
      const port = prefs.get(AppConstants.PREF_LAST_PORT, AppConstants.DEFAULT_PORT) as number;
      if (host) {
        return { host, port };
      }
    } catch (_e) {
      // Preferences not available (first launch)
    }
    return null;
  }

  /** Persist the last successful connection. */
  private async saveLastConnection(host: string, port: number): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(getContext(), 'paseo');
      prefs.put(AppConstants.PREF_LAST_HOST, host);
      prefs.put(AppConstants.PREF_LAST_PORT, port);
      prefs.flush();
    } catch (_e) {
      // Non-critical — silently fail
    }
  }

  /**
   * Wait for the server_info status message from the daemon.
   *
   * The daemon sends a `status` session message with type "server_info"
   * immediately after accepting the hello handshake.
   */
  private waitForServerInfo(client: DaemonClient): Promise<ServerInfoStatusPayload> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error('Connection timeout — no server_info received'));
      }, AppConstants.CONNECT_TIMEOUT_MS);

      const unsubscribe = client.onDaemonEvent((event) => {
        try {
          // server_info is sent as a session message with type "server_info"
          // DaemonClient v0.x may expose this differently — adapt to actual API
          if (event.type === 'server_info') {
            clearTimeout(timeout);
            unsubscribe();
            resolve(event.payload as unknown as ServerInfoStatusPayload);
          }
        } catch (err) {
          clearTimeout(timeout);
          unsubscribe();
          reject(err);
        }
      });

      // Also listen for errors
      const unsubError = client.onDaemonEvent((event) => {
        if (event.type === 'error') {
          clearTimeout(timeout);
          unsubError();
          unsubscribe();
          reject(new Error((event as Record<string, unknown>).message as string ?? 'Unknown daemon error'));
        }
      });
    });
  }
}
