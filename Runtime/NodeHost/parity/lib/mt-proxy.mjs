import { randomBytes } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { fetchResponse } from './http.mjs';
import { normalizeHeaders } from './playback.mjs';
import { log } from '../../diagnostics.mjs';

// Multi-thread (MT) local proxy for play addresses unwrapped from the client
// app's own loopback proxy (`/proxy?thread=…&chunkSize=…&url=…`, build 30).
// Swift registers the unwrapped CDN address here over the authenticated
// control channel and receives an opaque-token loopback URL in return; the
// player then reads that URL with ordinary Range GETs while this module fans
// each span out to at most `thread` parallel upstream Range fetches on an
// absolute chunk grid. RAM only: nothing here touches the disk media cache,
// its quotas, or forward-media. Diagnostics never see header values or the
// upstream URL — a registration is identified by token prefix only.

const MIN_CHUNK_BYTES = 64 * 1024;
const MAX_CHUNK_BYTES = 1024 ** 2;
const DEFAULT_CHUNK_KB = 256;
const MAX_THREAD = 10;
const WINDOW_BYTES = 16 * 1024 ** 2;         // issued-but-undelivered lead: per-request byte gate AND per-registration hard ceiling
const RESUME_BYTES = 8 * 1024 ** 2;          // per-request byte gate resumes at half the window (hysteresis on the byte gate only)
const CACHE_BYTES = 8 * 1024 ** 2;           // per-registration chunk cache (build 33 rebalance: window 8→16 MiB, cache 16→8 MiB; window + cache still = REGISTRATION_BYTES)
const REGISTRATION_BYTES = 24 * 1024 ** 2;   // per-registration ceiling (window + cache)
const GLOBAL_BYTES = 48 * 1024 ** 2;         // across all registrations
const MAX_REGISTRATIONS = 4;
const IDLE_TTL_MS = 20 * 60_000;             // sliding, from last player request
const ABSOLUTE_TTL_MS = 6 * 3600_000;        // from mint
const PROBE_TIMEOUT_MS = 6_000;
const CHUNK_TIMEOUT_MS = 15_000;
const RETRY_BACKOFFS_MS = [200, 600];        // two retries, three attempts per chunk

// Cross-origin redirects keep only negotiation headers; credentials stay on
// the origin that received them (scopedMediaHeaders in media-cache.mjs).
const crossOriginHeaders = new Set(['accept', 'accept-language', 'user-agent', 'referer', 'origin', 'cache-control', 'pragma']);

function scopedHeaders(headers, source, target) {
  const entries = [...new Headers(headers)];
  return Object.fromEntries(source.origin === target.origin
    ? entries : entries.filter(([name]) => crossOriginHeaders.has(name.toLowerCase())));
}

class MtError extends Error {
  constructor(failure, { retryable = true } = {}) {
    super(failure);
    this.failure = failure;      // error *class* only — safe for a 502 body
    this.retryable = retryable;
  }
}

const abortError = () => new MtError('aborted', { retryable: false });

function awaitAbortable(promise, signal) {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortError());
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(
      value => { signal.removeEventListener('abort', onAbort); resolve(value); },
      error => { signal.removeEventListener('abort', onAbort); reject(error); });
  });
}

function parseRange(header, total) {
  if (header == null) return { start: 0, end: total - 1 };
  const match = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim());
  if (!match || (!match[1] && !match[2])) return null;
  if (!match[1]) {
    const count = Number(match[2]);
    if (!Number.isSafeInteger(count) || count <= 0) return null;
    return { start: Math.max(0, total - count), end: total - 1 };
  }
  const start = Number(match[1]);
  const end = match[2] ? Math.min(Number(match[2]), total - 1) : total - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= total || start > end) return null;
  return { start, end };
}

export class MtProxy {
  constructor({ baseUrl = () => '', request = fetchResponse } = {}) {
    this.baseUrl = typeof baseUrl === 'function' ? baseUrl : () => baseUrl;
    this.request = request;
    this.routes = new Map();
    this.bytes = 0;              // global accounted bytes (chunk caches + uncached held chunks)
    this.closed = false;
    this.sweeper = setInterval(() => this.sweep(), 60_000);
    this.sweeper.unref?.();
  }

  // MARK: registration

  async register(params = {}) {
    if (this.closed) throw new Error('mt proxy closed');
    const raw = String(params.url || '');
    let parsed;
    try { parsed = new URL(raw); } catch { throw new Error('mt: invalid url'); }
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('mt: unsupported scheme');
    const threadInput = Math.floor(Number(params.thread));
    const thread = Number.isFinite(threadInput) ? Math.min(MAX_THREAD, Math.max(2, threadInput)) : MAX_THREAD;
    const chunkInput = Number(params.chunkSizeKB);
    const requestedBytes = Math.floor((Number.isFinite(chunkInput) && chunkInput > 0 ? chunkInput : DEFAULT_CHUNK_KB) * 1024);
    // Build 33 (H2): the MT grid is floored at 1 MiB — dou fetches quark/UC in
    // 1 MiB chunks, and at 256 KiB the fixed per-request cost (TTFB, redirect
    // hops) is amortised 4× worse. A larger param is still honoured only up
    // to the existing 1 MiB clamp ceiling, so the grid is effectively 1 MiB.
    const chunkBytes = Math.min(MAX_CHUNK_BYTES, Math.max(MIN_CHUNK_BYTES,
      Math.max(requestedBytes, MAX_CHUNK_BYTES)));
    const headers = normalizeHeaders(params.headers);
    // Probe exactly like the reference engines: one `bytes=0-0` GET. Anything
    // but a 206 with a parseable total fails registration and Swift falls
    // back to the direct address — MT never engages on an unproven origin.
    const probe = await this.fetchOnce(raw, headers, 0, 0, null, PROBE_TIMEOUT_MS);
    if (probe.status !== 206) throw new Error(`mt: probe upstream ${probe.status}`);
    const total = Number(/^bytes 0-0\/(\d+)$/.exec(probe.headers.get('content-range') || '')?.[1]);
    if (!Number.isSafeInteger(total) || total <= 0) throw new Error('mt: probe range mismatch');
    this.sweep();
    // Capacity: minting reserves one registration ceiling against the global
    // bound; the coldest registration is evicted to make room, and if two
    // hot plays still fill the ceiling registration refuses (Swift falls
    // back to direct) rather than queueing.
    while (this.routes.size >= MAX_REGISTRATIONS || this.bytes + REGISTRATION_BYTES > GLOBAL_BYTES) {
      const victim = this.coldest(null);
      if (!victim) throw new Error('mt: capacity');
      this.removeRegistration(victim);
    }
    const token = randomBytes(24).toString('hex');
    const format = String(params.format || '');
    const extension = /^[a-z\d]{1,8}$/i.test(format) ? format.toLowerCase()
      : parsed.pathname.match(/\.([a-z\d]{1,8})$/i)?.[1]?.toLowerCase() || 'bin';
    const registration = {
      token, url: raw, headers, thread, chunkBytes, total,
      contentType: probe.headers.get('content-type') || 'application/octet-stream',
      etag: probe.headers.get('etag') || '',
      lastModified: probe.headers.get('last-modified') || '',
      createdAt: Date.now(), lastAccessAt: Date.now(),
      cache: new Map(), cacheBytes: 0, heldBytes: 0,
      inflight: new Map(), undeliveredBytes: 0,
      stats: {
        bornAt: Date.now(), lastActivityAt: Date.now(),
        fetchesStarted: 0, fetchesCompleted: 0, activeFetches: 0, peakInflight: 0,
        bytesDelivered: 0, windowHighWater: 0,
        latencyCount: 0, latencySumMs: 0, latencySamples: [],
        retries: 0, chunkFailures: 0, byteParks: 0, ceilingQueues: 0,
        emitted: false,
      },
      dead: false, cleaned: false, deathFailure: '',
      controller: new AbortController(),
      cond: null, notify: null,
    };
    registration.cond = this.makeCond(registration);
    this.routes.set(token, registration);
    return { url: `${this.baseUrl()}/mt/${token}.${extension}`, total, contentType: registration.contentType, acceptRanges: true };
  }

  makeCond(registration) {
    let resolve;
    const promise = new Promise(res => { resolve = res; });
    registration.notify = () => {
      const current = registration.cond;
      registration.cond = this.makeCond(registration);
      current?.resolve();
    };
    return { promise, resolve };
  }

  coldest(except) {
    let victim = null;
    for (const registration of this.routes.values())
      if (registration !== except && (!victim || registration.lastAccessAt < victim.lastAccessAt)) victim = registration;
    return victim;
  }

  expired(registration, now = Date.now()) {
    return now - registration.lastAccessAt > IDLE_TTL_MS || now - registration.createdAt > ABSOLUTE_TTL_MS;
  }

  sweep() {
    for (const registration of [...this.routes.values()])
      if (this.expired(registration)) this.removeRegistration(registration);
  }

  // One MTSTATS summary line per registration, emitted when it closes,
  // evicts or is invalidated. Token prefix only — never headers, never the
  // upstream URL (not even its host).
  emitStats(registration) {
    const stats = registration.stats;
    if (!stats || stats.emitted) return;
    stats.emitted = true;
    const lifeMs = Math.max(1, stats.lastActivityAt - stats.bornAt);
    const samples = [...stats.latencySamples].sort((a, b) => a - b);
    const p95 = samples.length ? samples[Math.min(samples.length - 1, Math.floor(samples.length * 0.95))] : 0;
    const avgMs = stats.latencyCount ? Math.round(stats.latencySumMs / stats.latencyCount) : 0;
    const bps = Math.round(stats.bytesDelivered * 1000 / lifeMs);
    log(`MTSTATS tok=${registration.token.slice(0, 8)} life_ms=${lifeMs} fetches_started=${stats.fetchesStarted} fetches_completed=${stats.fetchesCompleted} peak_inflight=${stats.peakInflight} bytes_delivered=${stats.bytesDelivered} achieved_bps=${bps} lat_avg_ms=${avgMs} lat_p95_ms=${Math.round(p95)} retries=${stats.retries} chunk_failures=${stats.chunkFailures} byte_parks=${stats.byteParks} ceiling_queues=${stats.ceilingQueues} window_hwm_bytes=${stats.windowHighWater}`);
  }

  removeRegistration(registration) {
    this.emitStats(registration);
    if (this.routes.get(registration.token) === registration) this.routes.delete(registration.token);
    registration.dead = true;
    registration.controller.abort();
    if (!registration.cleaned) {
      registration.cleaned = true;
      this.bytes -= registration.cacheBytes + registration.heldBytes;
      registration.cache.clear();
      registration.cacheBytes = 0;
      registration.heldBytes = 0;
    }
    registration.notify?.();
  }

  killRegistration(registration, failure) {
    // A 401/403 means the signed upstream address is dead; retrying it for
    // the rest of the TTL would only hammer the CDN. Invalidate at once:
    // live requests fail with this class, later requests 404.
    registration.deathFailure ||= failure;
    log(`MTLIMIT tok=${registration.token.slice(0, 8)} event=auth_kill failure=${String(failure).replace(/\s+/g, '_')}`);
    this.removeRegistration(registration);
  }

  close() {
    this.closed = true;
    clearInterval(this.sweeper);
    for (const registration of [...this.routes.values()]) this.removeRegistration(registration);
  }

  // MARK: upstream fetch

  // One Range GET with scoped-credential redirect following (fetchScopedMedia
  // semantics on top of fetchResponse). Returns the status and headers for
  // any reply; the body is read only for a 206, where it is bounded by the
  // chunk grid.
  async fetchOnce(raw, headers, start, end, signal, timeoutMs) {
    let url = raw;
    let current = new Headers(headers);
    current.delete('range'); current.delete('if-range');
    for (let hop = 0; hop <= 5; hop++) {
      const requestHeaders = new Headers(current);
      requestHeaders.set('accept-encoding', 'identity');
      requestHeaders.set('range', `bytes=${start}-${end}`);
      const { response, release } = await this.request(url, {
        headers: requestHeaders, signal, timeoutMs, allowInsecureRedirect: true, followRedirect: false,
      });
      try {
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const location = response.headers.get('location');
          await response.body?.cancel().catch(() => {});
          if (!location || hop === 5) throw new MtError('upstream redirect', { retryable: false });
          const previous = new URL(url);
          const next = new URL(location, previous);
          if (!['http:', 'https:'].includes(next.protocol)) throw new MtError('upstream redirect', { retryable: false });
          next.username = ''; next.password = ''; next.hash = '';
          current = new Headers(scopedHeaders(current, previous, next));
          url = next.toString();
          continue;
        }
        if (response.status !== 206) {
          await response.body?.cancel().catch(() => {});
          return { status: response.status, headers: response.headers, body: Buffer.alloc(0) };
        }
        return { status: response.status, headers: response.headers, body: Buffer.from(await response.arrayBuffer()) };
      } finally { release(); }
    }
    throw new MtError('upstream redirect', { retryable: false });
  }

  async fetchChunk(registration, index, signal) {
    const stats = registration.stats;
    const startedAt = Date.now();
    stats.fetchesStarted++;
    stats.activeFetches++;
    if (stats.activeFetches > stats.peakInflight) stats.peakInflight = stats.activeFetches;
    try {
      return await this.fetchChunkAttempts(registration, index, signal, stats);
    } catch (error) {
      stats.chunkFailures++;
      throw error;
    } finally {
      stats.activeFetches--;
      const elapsed = Date.now() - startedAt;
      stats.latencyCount++;
      stats.latencySumMs += elapsed;
      // Small reservoir for a rough p95: fill to 256 samples, then overwrite
      // a pseudo-random slot so later chunks stay represented.
      if (stats.latencySamples.length < 256) stats.latencySamples.push(elapsed);
      else stats.latencySamples[Math.floor(Math.random() * stats.latencySamples.length)] = elapsed;
      stats.lastActivityAt = Date.now();
    }
  }

  async fetchChunkAttempts(registration, index, signal, stats) {
    const start = index * registration.chunkBytes;
    const end = Math.min(start + registration.chunkBytes, registration.total) - 1;
    let failure = 'upstream error';
    for (let attempt = 0; attempt <= RETRY_BACKOFFS_MS.length; attempt++) {
      if (attempt) { stats.retries++; await delay(RETRY_BACKOFFS_MS[attempt - 1], undefined, { signal }); }
      if (registration.dead) throw new MtError(registration.deathFailure || 'registration closed', { retryable: false });
      let result;
      try {
        result = await this.fetchOnce(registration.url, registration.headers, start, end, signal, CHUNK_TIMEOUT_MS);
      } catch (error) {
        if (signal.aborted || registration.dead) throw new MtError(registration.deathFailure || 'aborted', { retryable: false });
        failure = error instanceof MtError ? error.failure
          : error?.code === 'REQUEST_ABORTED' ? 'upstream timeout'
          : error?.code === 'NETWORK_ERROR' ? 'upstream network' : 'upstream error';
        if (error instanceof MtError && !error.retryable) throw error;
        continue;
      }
      if (result.status === 401 || result.status === 403) {
        this.killRegistration(registration, `upstream ${result.status}`);
        throw new MtError(`upstream ${result.status}`, { retryable: false });
      }
      if (result.status === 404) throw new MtError('upstream 404', { retryable: false });
      if (result.status !== 206) { failure = `upstream ${result.status}`; continue; }
      if (result.headers.get('content-range') !== `bytes ${start}-${end}/${registration.total}`
        || result.body.length !== end - start + 1) { failure = 'range mismatch'; continue; }
      stats.fetchesCompleted++;
      return result.body;
    }
    throw new MtError(failure);
  }

  // MARK: chunk cache / in-flight dedupe

  insertCache(registration, index, buffer) {
    if (buffer.length > CACHE_BYTES) return null;
    const existing = registration.cache.get(index);
    if (existing) return existing;
    while (this.bytes + buffer.length > GLOBAL_BYTES) {
      const victim = this.coldest(registration);
      if (!victim) break;
      this.removeRegistration(victim);
    }
    if (this.bytes + buffer.length > GLOBAL_BYTES) return null;
    while (registration.cacheBytes + buffer.length > CACHE_BYTES) {
      let evicted = false;
      for (const [key, entry] of registration.cache) {
        if (entry.pins > 0) continue;
        registration.cache.delete(key);
        registration.cacheBytes -= entry.buf.length;
        this.bytes -= entry.buf.length;
        evicted = true;
        break;
      }
      if (!evicted) return null;
    }
    const entry = { buf: buffer, pins: 0 };
    registration.cache.set(index, entry);
    registration.cacheBytes += buffer.length;
    this.bytes += buffer.length;
    return entry;
  }

  // Resolves to { buf, release }: the buffer is pinned (cache entry) or held
  // (uncached) until release, and the underlying fetch is aborted once its
  // last consumer leaves.
  getChunk(registration, index) {
    const hit = registration.cache.get(index);
    if (hit) {
      registration.cache.delete(index);
      registration.cache.set(index, hit);
      hit.pins++;
      let released = false;
      return Promise.resolve({
        buf: hit.buf,
        release: () => { if (!released) { released = true; hit.pins--; } },
      });
    }
    let entry = registration.inflight.get(index);
    if (!entry) {
      entry = { consumers: 0, settled: false, buf: null, cacheEntry: null, heldCounted: false, controller: new AbortController() };
      const signal = AbortSignal.any([registration.controller.signal, entry.controller.signal]);
      entry.promise = (async () => {
        const buffer = await this.fetchChunk(registration, index, signal);
        entry.buf = buffer;
        entry.cacheEntry = this.insertCache(registration, index, buffer);
        if (!entry.cacheEntry) {
          entry.heldCounted = true;
          registration.heldBytes += buffer.length;
          this.bytes += buffer.length;
        }
        return buffer;
      })().finally(() => {
        entry.settled = true;
        if (registration.inflight.get(index) === entry) registration.inflight.delete(index);
        registration.notify();
      });
      entry.promise.catch(() => {});
      registration.inflight.set(index, entry);
    }
    entry.consumers++;
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      entry.consumers--;
      if (entry.cacheEntry) entry.cacheEntry.pins--;
      if (entry.consumers <= 0) {
        if (!entry.settled) entry.controller.abort();
        if (entry.heldCounted) {
          entry.heldCounted = false;
          registration.heldBytes -= entry.buf.length;
          this.bytes -= entry.buf.length;
        }
      }
    };
    return entry.promise.then(() => {
      if (entry.cacheEntry) entry.cacheEntry.pins++;
      return { buf: entry.buf, release };
    });
  }

  // MARK: serving

  async handle(request, response, url) {
    if (!url.pathname.startsWith('/mt/')) return false;
    if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return true; }
    const token = /^\/mt\/([a-f\d]{48})\.[a-z\d]{1,8}$/i.exec(url.pathname)?.[1];
    const registration = token ? this.routes.get(token) : undefined;
    if (!registration || registration.dead || this.expired(registration)) {
      if (registration) this.removeRegistration(registration);
      response.writeHead(404).end();
      return true;
    }
    registration.lastAccessAt = Date.now();
    await this.serve(registration, request, response);
    return true;
  }

  async serve(registration, request, response) {
    const total = registration.total;
    const ifRange = request.headers['if-range'];
    const ifRangeMatches = !ifRange || ifRange === registration.etag || ifRange === registration.lastModified;
    let span, partial;
    if (!ifRangeMatches) {
      // RFC 7233: a mismatched If-Range means the validator changed, so the
      // range is ignored and the whole representation is served instead —
      // through the same chunk path.
      span = { start: 0, end: total - 1 };
      partial = false;
    } else {
      span = parseRange(request.headers.range, total);
      if (!span) {
        response.writeHead(416, { 'Content-Range': `bytes */${total}`, 'Cache-Control': 'no-store' }).end();
        return;
      }
      partial = request.headers.range != null;
    }
    const headers = {
      'Content-Type': registration.contentType,
      'Content-Length': span.end - span.start + 1,
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
    };
    if (registration.etag) headers.ETag = registration.etag;
    if (registration.lastModified) headers['Last-Modified'] = registration.lastModified;
    if (partial) headers['Content-Range'] = `bytes ${span.start}-${span.end}/${total}`;
    if (request.method === 'HEAD') { response.writeHead(partial ? 206 : 200, headers).end(); return; }

    const chunkBytes = registration.chunkBytes;
    const first = Math.floor(span.start / chunkBytes);
    const last = Math.floor(span.end / chunkBytes);
    const controller = new AbortController();
    response.on('close', () => { if (!response.writableEnded) controller.abort(); });
    const state = { windowBytes: 0, activeFetches: 0, failure: null };
    const slots = new Map();
    for (let index = first; index <= last; index++) {
      let resolve, reject;
      const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
      promise.catch(() => {});
      slots.set(index, { promise, resolve, reject });
    }
    const producer = this.produce(registration, state, slots, first, last, controller.signal)
      .catch(error => {
        state.failure ??= error;
        for (const slot of slots.values()) slot.reject(error);
      });
    try {
      // The first covering chunk gates the response: a failure here is still
      // a clean 502, never a truncated 206.
      let handle = await awaitAbortable(slots.get(first).promise, controller.signal);
      response.writeHead(partial ? 206 : 200, headers);
      for (let index = first; ; index++) {
        if (index > first) handle = await awaitAbortable(slots.get(index).promise, controller.signal);
        const chunkStart = index * chunkBytes;
        const slice = handle.buf.subarray(
          Math.max(0, span.start - chunkStart),
          Math.min(handle.buf.length, span.end - chunkStart + 1));
        // Build 33 (H3): a chunk counts as delivered the moment it is handed
        // to response.write() — the fetch window releases at write(), not
        // after drain. The drain wait still applies backpressure before the
        // next chunk is written, so at most one chunk sits in the socket
        // buffer beyond the accounting and no new buffer is introduced.
        const backpressured = slice.length ? !response.write(slice) : false;
        handle.release();
        state.windowBytes -= handle.buf.length;
        registration.undeliveredBytes -= handle.buf.length;
        registration.stats.bytesDelivered += slice.length;
        registration.stats.lastActivityAt = Date.now();
        registration.lastAccessAt = Date.now();
        registration.notify();
        if (backpressured)
          await awaitAbortable(new Promise(resolve => response.once('drain', resolve)), controller.signal);
        if (index === last) break;
      }
      response.end();
    } catch (error) {
      controller.abort();
      for (const slot of slots.values()) slot.promise.then(handle => handle.release(), () => {});
      if (!response.headersSent && !response.destroyed) {
        const failure = registration.deathFailure || state.failure?.failure || error?.failure || 'upstream error';
        response.writeHead(502, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
        response.end(`mt ${failure}`);
      } else if (!response.writableEnded) {
        // A correct Content-Length was already promised; a reset is cleaner
        // than a truncated body.
        response.destroy();
      }
    } finally {
      await producer.catch(() => {});
      registration.undeliveredBytes -= state.windowBytes;
      state.windowBytes = 0;
      registration.notify();
    }
  }

  // Issues covering chunks in index order with completion-driven refill
  // (build 33, H1): a replacement fetch launches as soon as one of THIS
  // request's fetches settles, sustaining up to `thread` of this request's
  // fetches in flight whenever the byte window allows — there is no
  // chunk-count park latch and no delivery-cursor gate. Accounting is
  // per-request (H4): this request parks on its own byte window (with
  // hysteresis on the byte gate only) and on its own in-flight count; the
  // registration-global counter survives only as a hard ceiling — when a
  // second overlapping request would push the registration over it, the
  // producer queues at the ceiling instead of both producers parking at a
  // shared low threshold. Delivery (in serve) is strictly in order but
  // streams each chunk as soon as its predecessors are out.
  async produce(registration, state, slots, first, last, signal) {
    const chunkBytes = registration.chunkBytes;
    const stats = registration.stats;
    let byteParked = false;
    let ceilingQueued = false;
    for (let index = first; index <= last; index++) {
      const length = Math.min(chunkBytes, registration.total - index * chunkBytes);
      for (;;) {
        if (signal.aborted) throw abortError();
        if (registration.dead) throw new MtError(registration.deathFailure || 'registration closed', { retryable: false });
        // Per-request byte gate: park at the window, resume at half of it.
        if (!byteParked && state.windowBytes + length > WINDOW_BYTES) { byteParked = true; stats.byteParks++; }
        if (byteParked && state.windowBytes <= RESUME_BYTES) byteParked = false;
        // Registration-global hard ceiling (RAM bound, not a pace gate).
        const atCeiling = !byteParked && registration.undeliveredBytes + length > WINDOW_BYTES
          && state.windowBytes + length <= WINDOW_BYTES;
        if (atCeiling && !ceilingQueued) { ceilingQueued = true; stats.ceilingQueues++; }
        if (!atCeiling) ceilingQueued = false;
        if (byteParked || atCeiling || state.activeFetches >= registration.thread) {
          await awaitAbortable(registration.cond.promise, signal);
          continue;
        }
        break;
      }
      state.windowBytes += length;
      registration.undeliveredBytes += length;
      if (registration.undeliveredBytes > stats.windowHighWater)
        stats.windowHighWater = registration.undeliveredBytes;
      state.activeFetches++;
      const slot = slots.get(index);
      this.getChunk(registration, index).then(
        handle => { state.activeFetches--; registration.notify(); slot.resolve(handle); },
        error => { state.activeFetches--; registration.notify(); slot.reject(error); });
    }
  }
}
