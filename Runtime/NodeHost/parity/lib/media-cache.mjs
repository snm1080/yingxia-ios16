import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fetchResponse } from './http.mjs';
import { normalizeHeaders } from './playback.mjs';
import { RequestBudget } from './request-budget.mjs';
import { ForwardMediaReader } from './forward-media.mjs';

const GiB = 1024 ** 3;
const httpUrl = value => typeof value === 'string' && /^https?:\/\//i.test(value);
const responseHeaders = ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified'];
const crossOriginMediaHeaders = new Set(['accept', 'accept-language', 'user-agent', 'referer', 'origin', 'cache-control', 'pragma']);

// Match native WebMediaCapture.redirectHeaders: CDNs commonly require browser
// negotiation headers, while cookies, authorization and source-specific secrets
// belong only to the origin that received them.
export function scopedMediaHeaders(headers, source, target) {
  const entries = [...new Headers(headers)];
  return Object.fromEntries(new URL(source).origin === new URL(target).origin
    ? entries : entries.filter(([name]) => crossOriginMediaHeaders.has(name)));
}

// Speculative requests must not carry source cookies or custom credentials
// across a redirect to a different origin (including subsequent HLS children).
export async function fetchScopedMedia(address, options = {}, request = fetchResponse) {
  let url = address, headers = new Headers(options.headers);
  for (let hop = 0; hop <= 5; hop++) {
    const upstream = await request(url, { ...options, headers, followRedirect: false });
    if (![301, 302, 303, 307, 308].includes(upstream.response.status))
      return { ...upstream, scopedHeaders: upstream.headers || Object.fromEntries(headers) };
    const location = upstream.response.headers.get('location');
    upstream.release(); await upstream.response.body?.cancel();
    if (!location || hop === 5) throw new Error('Invalid media redirect');
    const previous = new URL(upstream.url), next = new URL(location, previous);
    if (!options.allowInsecureRedirect && previous.protocol === 'https:' && next.protocol === 'http:')
      throw new Error('Insecure media redirect');
    next.username = ''; next.password = ''; next.hash = '';
    headers = new Headers(scopedMediaHeaders(upstream.headers || headers, previous, next));
    // Range and validators describe the response, and do not expose credentials.
    for (const name of ['range', 'if-range', 'accept-encoding'])
      if (new Headers(options.headers).has(name)) headers.set(name, new Headers(options.headers).get(name));
    url = next.toString();
  }
}
export function videoCacheSettings(value = {}) {
  return { enabled: typeof value.enabled === 'boolean' ? value.enabled : true,
    sizeGB: [1, 2, 3, 4].includes(value.sizeGB) ? value.sizeGB : 1 };
}
function span(range, total) {
  if (!Number.isSafeInteger(total) || total <= 0) return null;
  if (!range) return { start: 0, end: total - 1 };
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (!match || !match[1] && !match[2]) return null;
  const start = match[1] ? Number(match[1]) : Math.max(0, total - Number(match[2]));
  const end = match[1] && match[2] ? Math.min(total - 1, Number(match[2])) : total - 1;
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && start <= end && start < total ? { start, end } : null;
}
function description(response) {
  if (response.headers.has('content-encoding') && response.headers.get('content-encoding') !== 'identity') return null;
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
  const total = response.status === 206 && range ? Number(range[3]) : response.status === 200 ? Number(response.headers.get('content-length')) : 0;
  if (!Number.isSafeInteger(total) || total <= 0) return null;
  const start = range ? Number(range[1]) : 0, end = range ? Number(range[2]) : total - 1;
  if (!Number.isSafeInteger(start) || start < 0 || end < start || end >= total) return null;
  const length = response.headers.get('content-length');
  if (length !== null && Number(length) !== end - start + 1) return null;
  const etag = response.headers.get('etag') || '';
  // An Accept-Ranges header alone is not proof: some music origins advertise
  // bytes but ignore every Range. Only join a cached prefix after an actual 206.
  return { total, start, end, ranges: response.status === 206,
    type: response.headers.get('content-type') || 'application/octet-stream',
    validator: !etag.startsWith('W/') && etag ? etag : response.headers.get('last-modified') || '',
    etag, modified: response.headers.get('last-modified') || '' };
}

async function sniffManifest(upstream, signal, timeoutMs) {
  const response = upstream.response;
  if (/(?:mpegurl|dash\+xml)/i.test(response.headers.get('content-type') || '')) return true;
  if (!response.ok || !response.body || response.status === 206 && !/^bytes 0-/.test(response.headers.get('content-range') || '')) return false;
  const iterator = response.body[Symbol.asyncIterator]();
  const parts = []; let size = 0, prefix = '', format = '';
  try {
    while (size < 256) {
      const timer = setTimeout(() => upstream.controller.abort(), timeoutMs); timer.unref?.();
      let next;
      try { next = await iterator.next(); } finally { clearTimeout(timer); }
      signal.throwIfAborted();
      if (next.done) break;
      parts.push(Buffer.from(next.value)); size += next.value.length;
      prefix = Buffer.concat(parts).toString('utf8', 0, 256).replace(/^\uFEFF/, '').trimStart();
      if (/^#EXTM3U[\r\n]/.test(prefix)) { format = 'application/vnd.apple.mpegurl'; break; }
      if (/^(?:<\?xml[\s\S]*?\?>\s*)?<MPD[\s>]/.test(prefix)) { format = 'application/dash+xml'; break; }
      if (prefix && !'#EXTM3U'.startsWith(prefix) && !/^#EXTM3U\r?$/.test(prefix)
        && !'<?xml'.startsWith(prefix) && !'<MPD'.startsWith(prefix) && !/^<\?xml\b/.test(prefix)) break;
    }
  } catch (error) { await iterator.return?.().catch(() => {}); throw error; }
  const headers = new Headers(response.headers); if (format) headers.set('content-type', format);
  const replay = Readable.from((async function* () {
    try { yield* parts; while (true) { const next = await iterator.next(); if (next.done) return; yield next.value; } }
    finally { await iterator.return?.().catch(() => {}); }
  })());
  upstream.response = new Response(Readable.toWeb(replay), { status: response.status, headers });
  return !!format;
}

async function concurrencyRejected(response) {
  // Ali OSS may keep a cancelled download in its callback's concurrency count
  // briefly. Never retry an arbitrary 403 or buffer an unbounded error body.
  const length = Number(response.headers.get('content-length'));
  if (response.status !== 403 || !Number.isSafeInteger(length) || length <= 0 || length > 16384
    || !/xml/i.test(response.headers.get('content-type') || '')) return false;
  const reader = response.clone().body?.getReader();
  if (!reader) return false;
  const chunks = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 16384) return false;
      chunks.push(value);
    }
    const body = Buffer.concat(chunks).toString('utf8');
    return /<Code>RequestDeniedByCallback<\/Code>/.test(body)
      && /<Message>[^<]*\bExceedMaxConcurrency\b[^<]*<\/Message>/.test(body);
  } finally { void reader.cancel().catch(() => {}); }
}

// Raw media blocks are shared by repeated reads within one playback session.
// Forward reads retain the existing upstream connection and Range semantics;
// caching adds no source download threads or wait for a complete media file.
export class MediaCache {
  constructor({ dataDirectory, baseUrl, blockBytes = 1024 ** 2, reserveBytes = 64 * 1024 ** 2,
    idleTimeoutMs = 15000, writeBufferBytes = 4 * 1024 ** 2, request = fetchResponse } = {}) {
    this.root = path.join(dataDirectory, 'video-cache');
    this.directory = path.join(this.root, `${process.pid}-${randomUUID()}`);
    this.baseUrl = typeof baseUrl === 'function' ? baseUrl : () => baseUrl;
    Object.assign(this, { blockBytes, reserveBytes, idleTimeoutMs, writeBufferBytes, request });
    this.pendingBytes = 0; this.videoMaxBytes = GiB; this.useOrder = 0;
    // libavformat opens a seek/tail request before closing its previous read.
    // One slot deadlocks that handover on moov-at-end MP4 and resume/seek.
    this.requestBudget = new RequestBudget({ perResource: 2 });
    this.owners = new Map(); this.routes = new Map(); this.cleanups = new Set(); this.forwardWaiters = new Set();
    // Process-lifetime totals for released video owners. The per-session counters
    // die with their owner on release(), which made the settings page read 0
    // whenever no session was live; the released totals keep the page honest
    // ("cached so far this run") without changing any cache behavior.
    this.lifetime = { bytes: 0, written: 0, hits: 0, networkBytes: 0 };
    this.tail = Promise.resolve(); this.closed = false;
    this.ready = this.initialize();
    this.ready.catch(() => {});
  }
  async initialize() {
    await fs.mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const entry of await fs.readdir(this.root, { withFileTypes: true })) {
      const match = /^(\d+)-[a-f\d-]{36}$/.exec(entry.name);
      if (!match || !entry.isDirectory() || entry.isSymbolicLink()) continue;
      let alive = true;
      try { process.kill(Number(match[1]), 0); } catch (error) { alive = error.code !== 'ESRCH'; }
      if (!alive) await fs.rm(path.join(this.root, entry.name), { recursive: true, force: true });
    }
    await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
  }
  createSession(id, settings = {}, maxBytes) {
    if (this.closed) return null;
    let owner = this.owners.get(id);
    if (!owner) {
      const policy = maxBytes === undefined && this.videoPolicy ? this.videoPolicy : videoCacheSettings(settings);
      if (maxBytes === undefined) this.videoMaxBytes = policy.enabled ? policy.sizeGB * GiB : 0;
      owner = { id, enabled: policy.enabled, maxBytes: maxBytes ?? policy.sizeGB * GiB, bytes: 0,
        blocks: new Map(), resources: new Map(), controller: new AbortController(), closed: false, hits: 0, written: 0, networkBytes: 0, nativeFallback: false, cacheRevision: 0,
        forwardReaders: new Set(), forwardBytes: 0 };
      this.owners.set(id, owner);
    }
    return owner;
  }
  resource(owner, address, headers = {}) {
    const normalized = normalizeHeaders(headers);
    const key = createHash('sha256').update(JSON.stringify([address, Object.entries(normalized).sort()])).digest('hex');
    let resource = owner.resources.get(key);
    if (!resource) {
      resource = { owner, key, address, headers: normalized, token: randomBytes(24).toString('hex'), pages: new Map(), pending: new Map(), meta: null };
      owner.resources.set(key, resource); this.routes.set(resource.token, resource);
    }
    return resource;
  }
  url(resource, format = '') {
    const extension = /^[a-z\d]{1,8}$/i.test(format) ? format
      : new URL(resource.address).pathname.match(/\.([a-z\d]{1,8})$/i)?.[1] || 'bin';
    return `${this.baseUrl()}/media-cache/${resource.token}.${extension}`;
  }
  adopt(oldId, id) {
    const owner = this.owners.get(oldId);
    if (!owner || owner.closed) return false;
    this.owners.delete(oldId); owner.id = id; this.owners.set(id, owner); return true;
  }
  async update(settings) {
    const policy = videoCacheSettings(settings);
    this.videoPolicy = policy;
    this.videoMaxBytes = policy.enabled ? policy.sizeGB * GiB : 0;
    for (const owner of this.owners.values()) {
      if (owner.music || owner.speculative) continue;
      const enabling = policy.enabled && !owner.enabled;
      owner.enabled = policy.enabled; owner.maxBytes = policy.enabled ? policy.sizeGB * GiB : 0;
      if (!policy.enabled) { owner.cacheRevision++; for (const resource of owner.resources.values()) resource.pending.clear(); }
      if (enabling) for (const reader of owner.forwardReaders) reader.revision = owner.cacheRevision;
    }
    await this.serial(async () => {
      for (const owner of this.owners.values()) if (!owner.music && !owner.speculative) await this.trim(owner, 0);
      await this.trimVideos(0);
    });
    this.wakeForward();
  }
  wakeForward() { for (const wake of this.forwardWaiters) wake(); this.forwardWaiters.clear(); }
  async reserveForward(owner, bytes, signal, urgent = () => false, revision = owner.cacheRevision) {
    while (true) {
      signal.throwIfAborted();
      const active = [...this.owners.values()].filter(value => !value.music && !value.speculative);
      const caching = owner.enabled && revision === owner.cacheRevision;
      const maximum = caching ? Math.min(owner.maxBytes, this.videoMaxBytes) : this.blockBytes;
      if (urgent() || owner.forwardBytes + bytes <= Math.max(bytes, maximum)
        && (!caching || active.reduce((size, value) => size + value.forwardBytes, 0) + bytes <= this.videoMaxBytes)) {
        owner.forwardBytes += bytes; return;
      }
      await new Promise((resolve, reject) => {
        const wake = () => { signal.removeEventListener('abort', abort); this.forwardWaiters.delete(wake); resolve(); };
        const abort = () => { this.forwardWaiters.delete(wake); reject(signal.reason); };
        this.forwardWaiters.add(wake); signal.addEventListener('abort', abort, { once: true });
        if (signal.aborted) abort();
      });
    }
  }
  serial(work) {
    const result = this.tail.catch(() => {}).then(work); this.tail = result.catch(() => {}); return result;
  }
  async remove(owner, block) {
    if (!owner.blocks.delete(block.id)) return;
    owner.bytes -= block.length;
    const pages = block.resource.pages.get(Math.floor(block.start / this.blockBytes));
    pages?.delete(block.id); if (!pages?.size) block.resource.pages.delete(Math.floor(block.start / this.blockBytes));
    await fs.rm(block.file, { force: true });
  }
  async trim(owner, reserve) {
    for (const block of [...owner.blocks.values()]) {
      if (owner.bytes + reserve <= owner.maxBytes) break;
      if (!block.pins) await this.remove(owner, block);
    }
  }
  async trimVideos(reserve) {
    const owners = [...this.owners.values()].filter(owner => !owner.music && !owner.speculative);
    // Playing media and an acquired next episode share the user's disk budget.
    // Music prefixes and speculative readers retain their own smaller limits.
    const maximum = Math.min(this.videoMaxBytes, Math.max(0, ...owners.map(owner => owner.maxBytes)));
    let size = owners.reduce((sum, owner) => sum + owner.bytes, 0);
    while (size + reserve > maximum) {
      let oldest;
      for (const owner of owners) {
        const block = [...owner.blocks.values()].find(value => !value.pins);
        if (block && (!oldest || block.used < oldest.used)) oldest = block;
      }
      if (!oldest) break;
      size -= oldest.length; await this.remove(oldest.resource.owner, oldest);
    }
  }
  async put(resource, start, bytes, revision = resource.owner.cacheRevision, { pin = false } = {}) {
    const owner = resource.owner;
    if (!owner.enabled || owner.closed || !bytes.length || bytes.length > owner.maxBytes) return;
    return await this.serial(async () => {
      if (!owner.enabled || owner.closed || revision !== owner.cacheRevision) return;
      let file;
      try {
        await this.ready;
        const id = `${resource.token}-${start}-${bytes.length}`;
        if (owner.blocks.has(id)) {
          const existing = owner.blocks.get(id);
          // A forward reader consumes the file returned here after dropping its
          // network buffer. Equal offsets and lengths cannot prove equal bytes
          // when a proxy omits validators (or reuses one incorrectly).
          if (pin && existing.digest !== createHash('sha256').update(bytes).digest('hex')) {
            // Keep already pinned readers intact and stream this new response
            // from its own buffers. Never replace its bytes with older data.
            throw new Error('cached media bytes changed');
          }
          if (pin) existing.pins = (existing.pins || 0) + 1;
          return existing;
        }
        await this.trim(owner, bytes.length);
        if (!owner.music && !owner.speculative) await this.trimVideos(bytes.length);
        const videoBytes = [...this.owners.values()].filter(value => !value.music && !value.speculative).reduce((size, value) => size + value.bytes, 0);
        if (owner.bytes + bytes.length > owner.maxBytes || !owner.music && !owner.speculative && videoBytes + bytes.length > this.videoMaxBytes) return;
        file = path.join(this.directory, id);
        if (!owner.checkedSpace || Date.now() - owner.checkedSpace > 5000) {
          const disk = await fs.statfs(this.directory); owner.checkedSpace = Date.now();
          if (disk.bavail * disk.bsize < this.reserveBytes + bytes.length) throw new Error('cache space exhausted');
        }
        await fs.writeFile(file, bytes, { mode: 0o600 });
        if (owner.closed || !owner.enabled || revision !== owner.cacheRevision) { await fs.rm(file, { force: true }); return; }
        const block = { id, file, start, length: bytes.length, resource, used: ++this.useOrder, pins: pin ? 1 : 0,
          digest: createHash('sha256').update(bytes).digest('hex') };
        owner.blocks.set(id, block); owner.bytes += bytes.length; owner.written += bytes.length;
        const page = Math.floor(start / this.blockBytes);
        if (!resource.pages.has(page)) resource.pages.set(page, new Map());
        resource.pages.get(page).set(id, block);
        return block;
      } catch {
        if (file) await fs.rm(file, { force: true }).catch(() => {});
        owner.enabled = false; owner.maxBytes = 0; owner.cacheRevision++;
        for (const entry of owner.resources.values()) entry.pending.clear();
        await this.trim(owner, 0).catch(() => {});
        this.wakeForward();
      }
    });
  }
  enqueue(resource, start, bytes, revision = resource.owner.cacheRevision) {
    const owner = resource.owner, id = `${resource.token}-${start}-${bytes.length}`;
    if (!owner.enabled || owner.closed || revision !== owner.cacheRevision || !bytes.length || bytes.length > owner.maxBytes
      || owner.blocks.has(id) || resource.pending.has(id) || this.pendingBytes + bytes.length > this.writeBufferBytes) return;
    // Disk latency never backpressures playback. Keep a bounded readable queue
    // for immediate repeat seeks; if storage falls behind, skip cache writes.
    const block = { id, start, length: bytes.length, data: Buffer.from(bytes) };
    resource.pending.set(id, block); this.pendingBytes += block.length;
    void this.put(resource, start, block.data, revision).catch(() => {}).finally(() => {
      resource.pending.delete(id); this.pendingBytes -= block.length;
    });
  }
  find(resource, position) {
    if (!resource.owner.enabled || resource.owner.closed) return null;
    return [...resource.pending.values(), ...(resource.pages.get(Math.floor(position / this.blockBytes))?.values() || [])]
      .filter(block => block.start <= position && position < block.start + block.length)
      .sort((a, b) => b.start + b.length - a.start - a.length)[0];
  }
  covers(resource, start, end) {
    for (let position = start; position <= end;) {
      const block = this.find(resource, position);
      if (!block) return false;
      position = block.start + block.length;
    }
    return true;
  }
  async read(resource, position, end, countHit = true) {
    const block = this.find(resource, position);
    if (!block) return null;
    try {
      const bytes = block.data || await fs.readFile(block.file);
      if (bytes.length !== block.length) return null;
      const owner = resource.owner;
      const stored = owner.blocks.get(block.id);
      if (stored) { stored.used = ++this.useOrder; owner.blocks.delete(block.id); owner.blocks.set(block.id, stored); }
      const data = bytes.subarray(position - block.start, Math.min(block.length, end - block.start + 1));
      if (countHit) owner.hits += data.length;
      return data;
    } catch { return null; }
  }
  async pinCachedRange(resource, start, end) {
    return this.serial(() => {
      const owner = resource.owner, blocks = [];
      if (!owner.enabled || owner.closed) return null;
      for (let position = start; position <= end;) {
        const block = this.find(resource, position);
        if (!block) return null;
        blocks.push(block); position = block.start + block.length;
      }
      const bytes = blocks.reduce((sum, block) => sum + block.length, 0);
      for (const block of blocks) block.pins = (block.pins || 0) + 1;
      owner.forwardBytes += bytes;
      return { owner, blocks, bytes, revision: owner.cacheRevision };
    });
  }
  async unpinCachedRange(lease) {
    if (!lease) return;
    const { owner, blocks, bytes, revision } = lease;
    await this.serial(async () => {
      for (const block of blocks) {
        block.pins = Math.max(0, (block.pins || 0) - 1);
        if (!block.pins && (!owner.enabled || revision !== owner.cacheRevision))
          await this.remove(owner, block).catch(() => {});
      }
      owner.forwardBytes = Math.max(0, owner.forwardBytes - bytes);
      await this.trim(owner, 0).catch(() => {});
      await this.trimVideos(0).catch(() => {});
      this.wakeForward();
    });
  }
  async open(resource, method, range, ifRange, signal) {
    const headers = new Headers(resource.headers);
    headers.set('accept-encoding', 'identity'); headers.delete('range'); headers.delete('if-range');
    if (range) headers.set('range', range);
    if (ifRange) headers.set('if-range', ifRange);
    const controller = new AbortController();
    const combined = AbortSignal.any([signal, controller.signal]);
    const lease = await this.requestBudget.acquire(resource.key, { signal: combined });
    let result;
    try {
      const options = { headers, signal: combined, method, timeoutMs: this.idleTimeoutMs, allowInsecureRedirect: true };
      for (let attempt = 0; ; attempt++) {
        result = resource.scopedCredentials || resource.sniffManifest ? await fetchScopedMedia(resource.address, options, this.request)
          : await this.request(resource.address, options);
        if (attempt >= 8 || method !== 'GET' || !await concurrencyRejected(result.response)) break;
        result.release(); await result.response.body?.cancel();
        // Keep the same bounded lease while the origin releases its old read.
        // The owner/request signal cancels this wait and prevents another fetch.
        // Real CDN cancellations took longer than 14 s to release. Stop after
        // a 32 s recovery window; never turn a persistent rejection into a loop.
        await delay(4000, undefined, { signal: combined });
      }
    } catch (error) { result?.release(); lease.release(); throw error; }
    // A movie can stream for hours. Only an idle read has a deadline, rather
    // than aborting a healthy connection after a fixed total duration.
    result.release();
    return { ...result, controller, signal: combined, releaseBudget: lease.release };
  }
  accept(resource, remote) {
    const meta = description(remote);
    if (!meta) return null;
    const before = resource.meta;
    if (before && (before.total !== meta.total || before.validator !== meta.validator))
      throw new Error('media changed during playback');
    resource.meta = { ...meta, ranges: meta.ranges || before?.ranges };
    return meta;
  }
  async *body(resource, upstream, meta, signal, maxBytes = Infinity) {
    const iterator = upstream.response.body?.[Symbol.asyncIterator]();
    if (!iterator) return;
    let savedAt = meta?.start || 0, pending = Buffer.alloc(0), received = 0;
    const revision = resource.owner.cacheRevision;
    try {
      while (true) {
        const timer = setTimeout(() => upstream.controller.abort(), this.idleTimeoutMs); timer.unref?.();
        let next;
        try { next = await iterator.next(); } finally { clearTimeout(timer); }
        signal.throwIfAborted();
        if (next.done) break;
        resource.owner.networkBytes += next.value.length;
        const bytes = Buffer.from(next.value).subarray(0, maxBytes - received); received += bytes.length;
        if (meta && received > meta.end - meta.start + 1) throw new Error('invalid media length');
        if (meta && resource.owner.enabled && revision === resource.owner.cacheRevision && !resource.owner.speculative) {
          let offset = 0;
          while (offset < bytes.length) {
            const remaining = this.blockBytes - (savedAt % this.blockBytes) - pending.length;
            const part = bytes.subarray(offset, offset + remaining); offset += part.length;
            pending = pending.length ? Buffer.concat([pending, part]) : part;
            if (pending.length === this.blockBytes - (savedAt % this.blockBytes)) {
              this.enqueue(resource, savedAt, pending, revision); savedAt += pending.length; pending = Buffer.alloc(0);
            }
          }
        }
        yield bytes;
        if (received >= maxBytes) break;
      }
      if (meta && received !== Math.min(maxBytes, meta.end - meta.start + 1)) throw new Error('truncated media response');
    } finally {
      // A demuxer often stops its header/tail read before a full cache block.
      // Keep the validated bytes already received, as we do for full blocks,
      // so a following seek does not reopen the same upstream header again.
      if (meta && pending.length) this.enqueue(resource, savedAt, pending, revision);
      upstream.controller.abort();
      await iterator.return?.().catch(() => {});
      upstream.releaseBudget?.();
    }
  }
  async *resumableBody(resource, upstream, meta, signal) {
    let position = meta.start, current = upstream, description = meta, retries = 0;
    const deadline = Date.now() + this.idleTimeoutMs;
    try {
      while (true) {
        try {
          for await (const chunk of this.body(resource, current, description, signal)) {
            position += chunk.length; yield chunk;
          }
          return;
        } catch (error) {
          signal.throwIfAborted();
          if (!meta.validator || position <= meta.start || position > meta.end || retries++ >= 2 || Date.now() >= deadline) throw error;
          current = await this.open(resource, 'GET', `bytes=${position}-${meta.end}`, meta.validator, signal);
          description = this.accept(resource, current.response);
          if (current.response.status !== 206 || !description || description.start !== position || description.end !== meta.end)
            throw new Error('HLS media changed or rejected resumed range');
        }
      }
    } finally {
      // `accept` can throw before body() installs its own cleanup. The resumed
      // input always belongs to this generator, including rejected metadata.
      current.controller.abort();
      await current.response.body?.cancel().catch(() => {});
      current.releaseBudget?.();
    }
  }
  playbackBody(resource, upstream, meta, signal, range) {
    if (resource.resumeOnTruncation && meta) return this.resumableBody(resource, upstream, meta, signal);
    if (resource.forwardCache && meta && resource.owner.enabled && !resource.owner.music && !resource.owner.speculative
      && (!range || /^bytes=\d+-$/.test(range)))
      return new ForwardMediaReader(this, resource, upstream, meta, signal).body();
    return this.body(resource, upstream, meta, signal);
  }
  async transfer(owner, address, headers, request, response, externalSignal) {
    const resource = typeof address === 'object' ? address : this.resource(owner, address, headers);
    const disconnected = new AbortController();
    const close = () => { if (!response.writableEnded) disconnected.abort(); };
    response.once('close', close);
    const signal = AbortSignal.any([owner.controller.signal, disconnected.signal, ...(externalSignal ? [externalSignal] : [])]);
    const range = typeof request.headers.range === 'string' ? request.headers.range : '';
    const ifRange = request.headers['if-range'];
    let upstream, cachedLease;
    try {
      signal.throwIfAborted();
      if (resource.manifestURL && this.handleManifest) {
        await this.handleManifest(resource, request, response); return;
      }
      if (resource.validateOnRead) await this.revalidate(resource, signal);
      const cached = span(range, resource.meta?.total);
      // Quark's subscription proxy supplies ranges but no entity validator.
      // A completely acquired contiguous island can still be served safely as
      // a shorter 206; FFmpeg requests its next gap independently. Never splice
      // an unverifiable remote suffix onto those bytes in the same response.
      if (cached && /^bytes=\d+-$/.test(range) && resource.meta?.ranges
        && !resource.meta.validator && !resource.sampleVerified) {
        let cursor = cached.start;
        while (cursor <= cached.end) {
          const block = this.find(resource, cursor); if (!block) break;
          cursor = block.start + block.length;
        }
        if (cursor > cached.start) cached.end = Math.min(cached.end, cursor - 1);
      }
      // Wait for pending disk writes before pinning. Pinned response ranges
      // must outlive cache-off/clear, and share the forward-reader budget.
      if (cached && request.method !== 'HEAD' && (!ifRange || ifRange === resource.meta?.validator))
        cachedLease = await this.pinCachedRange(resource, cached.start, cached.end);
      const first = cached && (!ifRange || ifRange === resource.meta?.validator)
        && (resource.meta?.ranges && (resource.meta?.validator || resource.sampleVerified) || this.covers(resource, cached.start, cached.end))
        ? await this.read(resource, cached.start, cached.end, !cachedLease) : null;
      if (first && cached) {
        const meta = resource.meta;
        const outgoing = { 'Content-Type': meta.type, 'Content-Length': cached.end - cached.start + 1, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
        if (range) outgoing['Content-Range'] = `bytes ${cached.start}-${cached.end}/${meta.total}`;
        if (meta.etag) outgoing.ETag = meta.etag;
        if (meta.modified) outgoing['Last-Modified'] = meta.modified;
        response.writeHead(range ? 206 : 200, outgoing);
        if (request.method === 'HEAD') { response.end(); return; }
        const self = this;
        await pipeline(Readable.from((async function* () {
          let position = cached.start;
          while (position <= cached.end) {
            signal.throwIfAborted();
            const pinned = cachedLease?.blocks.find(block => block.start <= position && position < block.start + block.length);
            let bytes;
            if (pinned) {
              if (position === cached.start) bytes = first;
              else {
                const data = pinned.data || await fs.readFile(pinned.file);
                bytes = data.subarray(position - pinned.start, Math.min(data.length, cached.end - pinned.start + 1));
                if (data.length !== pinned.length || !bytes.length) throw new Error('cached media block unavailable');
              }
              owner.hits += bytes.length;
            } else { bytes = position === cached.start ? first : await self.read(resource, position, cached.end); }
            if (bytes) { position += bytes.length; yield bytes; continue; }
            if (!meta.validator && !resource.sampleVerified)
              throw new Error('unvalidated cached media range expired');
            // Keep a streaming read open-ended. Some subscription proxies
            // buffer bounded downloads as a batch; adding the full file's end
            // here can turn an ordinary seek into a multi-gigabyte download.
            const end = !range || /^bytes=\d+-$/.test(range) ? '' : cached.end;
            upstream = await self.open(resource, 'GET', `bytes=${position}-${end}`, meta.validator, signal);
            const next = self.accept(resource, upstream.response);
            if (upstream.response.status !== 206 || !next || next.start !== position || next.end !== cached.end)
              throw new Error('upstream rejected cached media range');
            const body = self.playbackBody(resource, upstream, next, signal, range);
            for await (const chunk of body) { position += chunk.length; yield chunk; }
          }
        })()), response, { signal });
      } else {
        upstream = await this.open(resource, request.method, range, ifRange, signal);
        const manifest = resource.sniffManifest && request.method !== 'HEAD'
          ? await sniffManifest(upstream, signal, this.idleTimeoutMs)
          : /(?:mpegurl|dash\+xml)/i.test(upstream.response.headers.get('content-type') || '');
        const remote = upstream.response, outgoing = { 'Cache-Control': 'no-store' };
        for (const name of responseHeaders) if (remote.headers.has(name)) outgoing[name] = remote.headers.get(name);
        if (remote.headers.has('content-encoding')) delete outgoing['content-length'];
        if (manifest && this.handleManifest) {
          await this.handleManifest(resource, request, response, upstream); return;
        }
        if (manifest) { owner.nativeFallback = true; response.writeHead(307, { Location: upstream.url, 'Cache-Control': 'no-store' }).end(); return; }
        const meta = owner.enabled ? this.accept(resource, remote) : null;
        response.writeHead(remote.status, outgoing);
        if (request.method === 'HEAD') { response.end(); return; }
        const body = this.playbackBody(resource, upstream, meta, signal, range);
        await pipeline(Readable.from(body), response, { signal });
      }
    } catch {
      if (response.headersSent || signal.aborted) response.destroy();
      else response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }).end('视频读取失败，请重试');
    } finally {
      upstream?.controller.abort();
      await upstream?.response.body?.cancel().catch(() => {});
      upstream?.releaseBudget?.();
      await this.unpinCachedRange(cachedLease);
      response.removeListener('close', close);
    }
  }
  async revalidate(resource, signal) {
    // First playback after a long preparation interval must check identity
    // before writing any cached bytes to the decoder.
    if (resource.validating) return resource.validating;
    resource.validating = (async () => {
      let upstream, valid = false;
      try {
        const before = resource.meta;
        if (resource.sampleValidation && before?.ranges) {
          let end = 0;
          while (this.find(resource, end)) { const block = this.find(resource, end); end = block.start + block.length; }
          const start = Math.max(0, end - 4096), cached = [];
          for (let position = start; position < end;) {
            const bytes = await this.read(resource, position, end - 1, false);
            if (!bytes) break;
            cached.push(bytes); position += bytes.length;
          }
          if (end > 0) {
            upstream = await this.open(resource, 'GET', `bytes=${start}-${end - 1}`, '', signal);
            const current = description(upstream.response);
            if (upstream.response.status === 206 && current?.total === before.total && current.start === start && current.end === end - 1) {
              const chunks = [];
              for await (const bytes of this.body(resource, upstream, current, signal, end - start)) chunks.push(bytes);
              valid = Buffer.concat(cached).equals(Buffer.concat(chunks));
            }
          }
          // This is scoped to one prepared URL and checks media bytes near the
          // splice point. Origins without entity validators cannot prove the
          // identity of unsampled regions; a mismatch always drops the cache.
          resource.sampleVerified = valid;
        } else {
          upstream = await this.open(resource, 'HEAD', '', '', signal);
          const current = description(upstream.response);
          valid = !!(before?.validator && current?.validator === before.validator && current.total === before.total);
        }
      } catch { signal.throwIfAborted(); }
      finally { upstream?.controller.abort(); await upstream?.response.body?.cancel().catch(() => {}); upstream?.releaseBudget?.(); }
      if (!valid) {
        await this.serial(async () => {
          for (const block of [...resource.owner.blocks.values()]) if (block.resource === resource) await this.remove(resource.owner, block);
        });
        resource.meta = null;
      }
      resource.validateOnRead = false;
    })().finally(() => { resource.validating = null; });
    return resource.validating;
  }
  async handle(request, response, url) {
    if (!url.pathname.startsWith('/media-cache/')) return false;
    if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return true; }
    const token = /^\/media-cache\/([a-f\d]{48})\.[a-z\d]{1,8}$/i.exec(url.pathname)?.[1];
    const resource = this.routes.get(token);
    if (!resource || resource.owner.closed) { response.writeHead(404).end(); return true; }
    if (url.searchParams.get('cacheOnly') === '1') {
      await this.preview(resource, request, response); return true;
    }
    await this.transfer(resource.owner, resource, {}, request, response); return true;
  }
  async preview(resource, request, response) {
    if (resource.manifestURL && this.handleManifest) {
      await this.handleManifest(resource, request, response, undefined, true); return;
    }
    // Scrubbing may inspect already acquired media, but must never borrow a
    // playback request slot or fill a cache miss with another upstream read.
    const meta = resource.meta, range = typeof request.headers.range === 'string' ? request.headers.range : '';
    const requested = span(range, meta?.total);
    const miss = () => response.writeHead(504, { 'Cache-Control': 'no-store' }).end();
    if (!resource.owner.enabled || resource.validateOnRead || !requested) { miss(); return; }
    const ifRange = request.headers['if-range'];
    if (ifRange && ifRange !== meta.validator) { miss(); return; }
    let end = requested.end;
    if (request.method !== 'HEAD') {
      if (/^bytes=\d+-$/.test(range)) {
        // FFmpeg starts with an open-ended GET, even when it only needs a few
        // probe bytes. Report a real partial range, including total file size,
        // so its later moov/target seeks can use other cached islands.
        let cursor = requested.start;
        while (cursor <= end) {
          const block = this.find(resource, cursor); if (!block) break;
          cursor = block.start + block.length;
        }
        end = Math.min(end, cursor - 1);
      }
      if (end < requested.start || !this.covers(resource, requested.start, end)) { miss(); return; }
    }
    const headers = { 'Content-Type': meta.type, 'Content-Length': end - requested.start + 1,
      'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
    if (range) headers['Content-Range'] = `bytes ${requested.start}-${end}/${meta.total}`;
    if (meta.etag) headers.ETag = meta.etag;
    if (meta.modified) headers['Last-Modified'] = meta.modified;
    response.writeHead(range ? 206 : 200, headers);
    if (request.method === 'HEAD') { response.end(); return; }
    const self = this;
    try {
      await pipeline(Readable.from((async function* () {
        for (let position = requested.start; position <= end;) {
          if (response.destroyed || resource.owner.closed) return;
          const bytes = await self.read(resource, position, end);
          // A concurrent eviction may invalidate a prepared range. End this
          // preview only; normal playback owns refilling and revalidation.
          if (!bytes) throw new Error('Preview cache block expired');
          position += bytes.length; yield bytes;
        }
      })()), response, { signal: resource.owner.controller.signal });
    } catch { response.destroy(); }
  }
  async prime(id, media, bytes = 2 * 1024 ** 2, signal = new AbortController().signal) {
    if (!httpUrl(media.url) || /^(?:m3u8|mpd)$/.test(media.format)) return media;
    const owner = this.createSession(id, { enabled: true }, bytes); owner.music = true;
    const resource = this.resource(owner, media.url, media.headers);
    const combined = AbortSignal.any([signal, owner.controller.signal]);
    const upstream = await this.open(resource, 'GET', `bytes=0-${bytes - 1}`, '', combined);
    try {
      const meta = this.accept(resource, upstream.response);
      if (!meta || meta.start !== 0) return media;
      for await (const _ of this.body(resource, upstream, meta, combined, bytes)) { /* Store only the bounded prefix. */ }
      await this.tail;
      return { ...media, originalUrl: media.url, url: this.url(resource, media.format) };
    } finally { upstream.controller.abort(); await upstream.response.body?.cancel().catch(() => {}); upstream.releaseBudget?.(); }
  }
  release(id) {
    const owner = this.owners.get(id);
    if (!owner) return Promise.resolve();
    if (!owner.music && !owner.speculative) {
      this.lifetime.bytes += owner.bytes; this.lifetime.written += owner.written;
      this.lifetime.hits += owner.hits; this.lifetime.networkBytes += owner.networkBytes;
    }
    owner.closed = true; owner.controller.abort(); this.owners.delete(id);
    for (const resource of owner.resources.values()) this.routes.delete(resource.token);
    this.wakeForward();
    const cleanup = Promise.allSettled([...owner.forwardReaders].map(reader => reader.finished)).then(() =>
      this.serial(async () => { for (const block of [...owner.blocks.values()]) await this.remove(owner, block); }));
    this.cleanups.add(cleanup); void cleanup.finally(() => this.cleanups.delete(cleanup)).catch(() => {});
    return cleanup;
  }
  statistics(id) {
    const owner = this.owners.get(id);
    return owner ? { bytes: owner.bytes, maxBytes: owner.maxBytes, hits: owner.hits, written: owner.written, networkBytes: owner.networkBytes, nativeFallback: owner.nativeFallback } : null;
  }
  videoStatistics() {
    const owners = [...this.owners.values()].filter(owner => !owner.music && !owner.speculative);
    return { bytes: owners.reduce((sum, owner) => sum + owner.bytes, 0) + this.lifetime.bytes, maxBytes: this.videoMaxBytes,
      sessions: owners.length, hits: owners.reduce((sum, owner) => sum + owner.hits, 0) + this.lifetime.hits,
      written: owners.reduce((sum, owner) => sum + owner.written, 0) + this.lifetime.written,
      networkBytes: owners.reduce((sum, owner) => sum + owner.networkBytes, 0) + this.lifetime.networkBytes };
  }
  async clearVideos() {
    const owners = [...this.owners.values()].filter(owner => !owner.music && !owner.speculative);
    for (const owner of owners) {
      owner.cacheRevision++;
      for (const resource of owner.resources.values()) resource.pending.clear();
    }
    this.wakeForward();
    await this.serial(async () => {
      for (const owner of owners) for (const block of [...owner.blocks.values()]) if (!block.pins) await this.remove(owner, block);
    });
  }
  async close() {
    this.closed = true;
    this.requestBudget.close();
    await Promise.all([...this.owners.keys()].map(id => this.release(id)));
    await Promise.allSettled([...this.cleanups]); await this.tail; await this.ready.catch(() => {});
    await fs.rm(this.directory, { recursive: true, force: true }).catch(error => {
      // Initialization can fail before this per-process directory exists.
      if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
    });
  }
}
