import { createLiveProtocol } from './live-danmaku-protocols.mjs';
import { connectLiveWebSocket } from './live-websocket.mjs';

export class LiveDanmakuService {
  constructor(emit, { batchMs = 100, maxPending = 128, retryMs = 1000, maxRetries = 5,
    heartbeatMs = 20000, timeoutMs = 10000, idleMs = 90000 } = {}) {
    this.emit = emit;
    this.options = { batchMs, maxPending, retryMs, maxRetries, heartbeatMs, timeoutMs, idleMs };
    this.active = null;
    this.lastScope = '';
    this.sequence = 0;
  }
  update(session, enabled) {
    const config = session?.liveDanmaku;
    const setupError = session?.liveDanmakuError;
    const key = (config || setupError) && JSON.stringify([session.id, session.mediaVersion || 0, config, setupError]);
    if (key && this.active?.key === key && this.active.enabled === enabled) return;
    this.close();
    if (!key) return;
    const scope = JSON.stringify([session.id, session.mediaVersion || 0]);
    if (scope !== this.lastScope) { this.lastScope = scope; this.sequence = 0; }
    const state = { key, enabled, config, sessionId: session.id, mediaVersion: session.mediaVersion || 0,
      pending: [], loaded: 0, retries: 0, connection: null };
    this.active = state;
    if (!enabled) { this.status(state, 'disabled'); return; }
    if (!config) { this.status(state, 'error', setupError); return; }
    this.connect(state);
  }
  status(state, phase, error = '') {
    if (this.active !== state) return;
    this.emit('live-danmaku-state', { sessionId: state.sessionId, mediaVersion: state.mediaVersion,
      phase, loaded: phase === 'live', count: state.loaded, ...(error ? { error } : {}) });
  }
  connect(state) {
    if (this.active !== state) return;
    const attempt = {};
    state.attempt = attempt;
    const current = () => this.active === state && state.attempt === attempt;
    const failed = error => {
      if (!current()) return;
      state.attempt = null;
      state.connection?.close(); state.connection = null;
      clearInterval(state.heartbeat); clearTimeout(state.batch);
      state.pending = []; state.batch = null;
      if (state.openedAt && Date.now() - state.openedAt > 60000) state.retries = 0;
      state.openedAt = 0;
      if (state.retries >= this.options.maxRetries) { this.status(state, 'error', error); return; }
      this.status(state, 'reconnecting', error);
      state.retry = setTimeout(() => this.connect(state), Math.min(30000, this.options.retryMs * 2 ** state.retries++));
      state.retry.unref?.();
    };
    let protocol;
    try { protocol = createLiveProtocol(state.config); }
    catch { this.status(state, 'error', '实时弹幕配置无效'); return; }
    this.status(state, state.retries ? 'reconnecting' : 'connecting');
    try {
      state.connection = connectLiveWebSocket(state.config, {
        open: () => {
          if (!current()) return;
          state.openedAt = Date.now();
          for (const packet of protocol.open()) state.connection?.send(packet);
          this.status(state, 'live');
          state.heartbeat = setInterval(() => {
            if (!current()) return;
            try {
              for (const packet of protocol.heartbeat()) state.connection?.send(packet);
              // Native platform heartbeats keep their protocol alive. Douyu
              // returns a non-final pong to RFC pings; only generic JSON feeds
              // use them. The receive watchdog still applies to every feed.
              if (state.config.platform === 'json') state.connection?.ping();
            } catch { failed('实时弹幕心跳失败'); }
          }, this.options.heartbeatMs);
          state.heartbeat.unref?.();
        },
        message: data => {
          if (!current()) return;
          try {
            const { comments, replies } = protocol.decode(data);
            for (const packet of replies) state.connection?.send(packet);
            if (!current() || !comments.length) return;
            state.pending.push(...comments.slice(-this.options.maxPending));
            if (state.pending.length > this.options.maxPending) state.pending.splice(0, state.pending.length - this.options.maxPending);
            if (!state.batch) {
              state.batch = setTimeout(() => {
                state.batch = null;
                if (!current()) return;
                const comments = state.pending; state.pending = [];
                state.loaded += comments.length;
                this.emit('live-danmaku', { sessionId: state.sessionId, mediaVersion: state.mediaVersion,
                  sequence: ++this.sequence, comments });
                this.status(state, 'live');
              }, this.options.batchMs);
              state.batch.unref?.();
            }
          } catch { failed('实时弹幕认证或数据解析失败，请重新打开直播间'); }
        },
        close: failed,
      }, this.options);
    } catch { failed('实时弹幕连接配置无效'); }
  }
  close() {
    const state = this.active;
    this.active = null;
    if (!state) return;
    state.connection?.close();
    clearInterval(state.heartbeat); clearTimeout(state.retry); clearTimeout(state.batch);
    state.pending = [];
  }
}
