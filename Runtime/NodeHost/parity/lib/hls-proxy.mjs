import { createHash, randomBytes } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fetchResponse } from './http.mjs';
import { normalizeHeaders } from './playback.mjs';
import { cleanHlsPlaylist } from './hls-cleaner.mjs';
import { fetchScopedMedia, scopedMediaHeaders } from './media-cache.mjs';

const httpUrl = value => typeof value === 'string' && /^https?:\/\//i.test(value);
function isHls(quality, inferProxy) {
  if (quality.format === 'm3u8' || /\.m3u8(?:[?#]|$)/i.test(quality.url)) return true;
  if (!inferProxy || quality.format) return false;
  try {
    const url = new URL(quality.url);
    if (!/\/(?:proxy|m3u8-clean)\/?$/i.test(url.pathname)) return false;
    if (/^(?:m3u8|hls)$/i.test(url.searchParams.get('type') || url.searchParams.get('format') || '')) return true;
    // Python proxies often hide a signed playlist in an encoded query value.
    // Inspect a parsed copy, keeping the original URL and its signature intact.
    return ['url', 'source'].some(name => {
      const target = url.searchParams.get(name);
      return httpUrl(target) && /\.m3u8$/i.test(new URL(target).pathname);
    });
  } catch { return false; }
}
const responseHeaders = ['content-type', 'content-range', 'accept-ranges', 'etag', 'last-modified'];

function finiteMedia(response) {
  const length = Number(response.headers.get('content-length'));
  if (![200, 206].includes(response.status) || !Number.isSafeInteger(length) || length <= 0
    || ![null, 'identity'].includes(response.headers.get('content-encoding'))) return null;
  let start = 0, end = length - 1, total = length;
  if (response.status === 206) {
    const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
    if (!range) return null;
    [start, end, total] = range.slice(1).map(Number);
    if (![start, end, total].every(Number.isSafeInteger) || start < 0 || end < start || end >= total || end - start + 1 !== length) return null;
  }
  const etag = response.headers.get('etag');
  const validatorName = etag && !etag.startsWith('W/') ? 'etag' : 'last-modified';
  return { start, end, total, length, validatorName, validator: response.headers.get(validatorName) };
}

// URLs are unguessable capabilities. Upstream addresses and credentials remain
// in memory; the endpoint never accepts an arbitrary target from the client.
export class HlsProxy {
  constructor({ baseUrl, timeoutMs = 60_000, maxPlaylistBytes = 8 * 1024 * 1024,
    liveRetentionMs = 5 * 60_000, liveResourceBytes = 8 * 1024 ** 2, now = Date.now } = {}) {
    this.baseUrl = typeof baseUrl === 'function' ? baseUrl : () => baseUrl;
    this.timeoutMs = timeoutMs;
    this.maxPlaylistBytes = maxPlaylistBytes;
    Object.assign(this, { liveRetentionMs, liveResourceBytes, now });
    this.contexts = new Map();
    this.sessions = new Map();
  }

  prepare(session, { enabled = true, forceProxy = false, mediaCache, cacheOwner } = {}) {
    if (!session?.id || session.parse || !this.baseUrl()) return session;
    session.qualities = (session.qualities || []).map(quality => {
      if (quality.hlsAdClean) {
        const existing = this.lookup(quality.url);
        if (existing) existing.context.enabled = enabled;
        return quality;
      }
      if ((!enabled && !forceProxy) || !httpUrl(quality.url) || !isHls(quality, !session.parse)) return quality;
      const token = randomBytes(24).toString('hex');
      const context = { token, sessionId: session.id, headers: normalizeHeaders(quality.headers),
        resources: new Map(), windows: new Map(), controller: new AbortController(), enabled,
        live: session.isLive === true || session.request?.isLive === true };
      if (mediaCache && cacheOwner && !context.live) Object.assign(context, { mediaCache, cacheOwner });
      this.contexts.set(token, context);
      if (!this.sessions.has(session.id)) this.sessions.set(session.id, new Set());
      this.sessions.get(session.id).add(token);
      const prepared = { ...quality, originalUrl: quality.url,
        originalHeaders: { ...quality.headers }, hlsAdClean: true,
        url: this.register(context, quality.url, true), format: 'm3u8' };
      if (httpUrl(quality.fallbackUrl)) {
        prepared.originalFallbackUrl = quality.fallbackUrl;
        prepared.fallbackUrl = this.register(context, quality.fallbackUrl, true);
      }
      return prepared;
    });
    // Stale sessions are normally released at commit/stop. This also bounds
    // retention for callers that forget to signal a replaced session.
    while (this.sessions.size > 16) this.release(this.sessions.keys().next().value);
    return session;
  }

  lookup(address) {
    let match;
    try { match = new URL(address).pathname.match(/^\/hls\/([a-f\d]{48})\/([a-f\d]{32})\.[a-z\d]{1,8}$/i); } catch { return null; }
    const context = match && this.contexts.get(match[1]), resource = context?.resources.get(match[2]);
    return resource ? { context, resource, id: match[2] } : null;
  }

  rewrite(context, resource, original, sourceUrl, scopedHeaders = context.headers) {
    const collected = new Set();
    const cleaned = cleanHlsPlaylist(original, sourceUrl, {
      enabled: context.enabled && !context.separateRenditions,
      rewriteUri: (target, { playlist }) => this.register(context, target, playlist, collected,
        context.speculative ? scopedMediaHeaders(scopedHeaders, sourceUrl, target)
          : context.cacheOwner ? scopedMediaHeaders(scopedHeaders, sourceUrl, target)
          : context.live ? (new URL(target).origin === new URL(sourceUrl).origin ? scopedHeaders : {}) : context.headers),
    });
    const live = /^#EXTINF:/m.test(original) && !/^#EXT-X-ENDLIST/m.test(original);
    const id = [...context.resources].find(([, item]) => item === resource)?.[0];
    this.retainPlaylist(context, id, collected, live);
    return cleaned.content;
  }

  register(context, url, playlist, collected, headers = context.headers) {
    if (!httpUrl(url)) return url;
    const id = createHash('sha256').update(JSON.stringify([playlist, url, headers])).digest('hex').slice(0, 32);
    if (!context.resources.has(id)) {
      if (context.resources.size >= 100_000) throw new Error('HLS playlist has too many resources');
      context.resources.set(id, { url, headers, playlist, seen: this.now(), live: false });
    }
    context.resources.get(id).seen = this.now();
    const resource = context.resources.get(id);
    if (!playlist && context.mediaCache && context.cacheOwner && !context.live && !resource.cachedMedia) {
      resource.cachedMedia = context.mediaCache.resource(context.cacheOwner, url, headers);
      resource.cachedMedia.scopedCredentials = true;
      resource.cachedMedia.resumeOnTruncation = true;
    }
    collected?.add(id);
    let extension = 'bin';
    try { extension = new URL(url).pathname.match(/\.([a-z\d]{1,8})$/i)?.[1] || extension; } catch {}
    return `${this.baseUrl()}/hls/${context.token}/${id}.${playlist ? 'm3u8' : extension}`;
  }

  retainPlaylist(context, owner, ids, live) {
    if (!live) {
      for (const id of ids) { const item = context.resources.get(id); if (item) item.vod = true; }
      return;
    }
    const previous = context.windows.get(owner)?.current || new Set();
    context.windows.delete(owner);
    context.windows.set(owner, { current: ids, previous });
    while (context.windows.size > 64) context.windows.delete(context.windows.keys().next().value);
    for (const id of ids) { const item = context.resources.get(id); if (item) item.live = true; }
    const protectedIds = new Set();
    for (const window of context.windows.values()) for (const id of [...window.current, ...window.previous]) protectedIds.add(id);
    let bytes = 0;
    for (const item of context.resources.values()) if (item.live && !item.vod) bytes += item.url.length * 2 + 128;
    const expiry = this.now() - this.liveRetentionMs;
    for (const [id, item] of context.resources) {
      if (!item.live || item.vod || item.playlist || protectedIds.has(id)) continue;
      if (item.seen < expiry || bytes > this.liveResourceBytes) {
        bytes -= item.url.length * 2 + 128;
        context.resources.delete(id);
      }
    }
  }

  release(sessionId) {
    for (const token of this.sessions.get(sessionId) || []) {
      this.contexts.get(token)?.controller.abort();
      this.contexts.delete(token);
    }
    this.sessions.delete(sessionId);
  }

  close() {
    for (const sessionId of this.sessions.keys()) this.release(sessionId);
  }

  async fetch(context, resource, options) {
    if (context.speculative || context.cacheOwner) return fetchScopedMedia(resource.url, { ...options, allowInsecureRedirect: true });
    if (!context.live) return fetchResponse(resource.url, options);
    // Live dispatchers can select an HTTP CDN from an HTTPS entry point.
    // Follow that media route without sending the subscription's credentials
    // or custom headers to a different origin, including its later playlists.
    let url = resource.url, headers = Object.fromEntries(new Headers(options.headers));
    const deadline = Date.now() + this.timeoutMs;
    for (let hop = 0; hop <= 5; hop++) {
      const upstream = await fetchResponse(url, { ...options, headers,
        timeoutMs: Math.max(1, deadline - Date.now()), followRedirect: false });
      if (![301, 302, 303, 307, 308].includes(upstream.response.status))
        return { ...upstream, scopedHeaders: upstream.headers };
      const location = upstream.response.headers.get('location');
      upstream.release();
      await upstream.response.body?.cancel();
      if (!location || hop === 5) throw new Error('Invalid live HLS redirect');
      const next = new URL(location, upstream.url);
      next.username = ''; next.password = ''; next.hash = '';
      headers = new URL(upstream.url).origin === next.origin ? upstream.headers : {};
      url = next.toString();
    }
  }

  async *mediaBody(context, resource, upstream, iterator, prefix, next, headers, signal) {
    const original = finiteMedia(upstream.response);
    const recoverable = resource.vod && !context.live && original?.validator;
    const deadline = Date.now() + this.timeoutMs;
    let received = 0, retries = 0, current = upstream;
    try {
      while (true) {
        try {
          for (const bytes of prefix) { received += bytes.length; yield bytes; }
          prefix = [];
          while (!next.done) {
            signal.throwIfAborted();
            next = await iterator.next();
            if (!next.done) {
              const bytes = Buffer.from(next.value);
              if (context.cacheOwner) context.cacheOwner.networkBytes += bytes.length;
              if (original && received + bytes.length > original.length) throw new Error('Invalid HLS media length');
              received += bytes.length; yield bytes;
            }
          }
          if (original && received !== original.length) throw new Error('Truncated HLS media');
          return;
        } catch (error) {
          signal.throwIfAborted();
          if (!recoverable || received <= 0 || received >= original.length || retries >= 2 || Date.now() >= deadline) throw error;
          retries++;
          current.release();
          await iterator.return?.().catch(() => {});
          const resumeHeaders = new Headers(headers);
          resumeHeaders.set('range', `bytes=${original.start + received}-${original.end}`);
          resumeHeaders.set('if-range', original.validator);
          current = await this.fetch(context, resource, { headers: resumeHeaders, signal, method: 'GET',
            timeoutMs: Math.max(1, deadline - Date.now()) });
          const resumed = finiteMedia(current.response);
          if (current.response.status !== 206 || !resumed || resumed.start !== original.start + received
            || resumed.end !== original.end || resumed.total !== original.total
            || current.response.headers.get(original.validatorName) !== original.validator) {
            await current.response.body?.cancel();
            throw new Error('HLS media changed or rejected the resumed range');
          }
          iterator = current.response.body[Symbol.asyncIterator]();
          next = { done: false };
        }
      }
    } finally { current.release(); await iterator.return?.().catch(() => {}); }
  }

  async handle(request, response, url, suppliedUpstream) {
    if (!url.pathname.startsWith('/hls/')) return false;
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, { Allow: 'GET, HEAD' }).end();
      return true;
    }
    const match = url.pathname.match(/^\/hls\/([a-f\d]{48})\/([a-f\d]{32})\.[a-z\d]{1,8}$/i);
    const context = match && this.contexts.get(match[1]);
    const resource = context?.resources.get(match[2]);
    if (!resource) {
      response.writeHead(404).end();
      return true;
    }
    const disconnected = new AbortController();
    const onClose = () => { if (!response.writableEnded) disconnected.abort(); };
    response.once('close', onClose);
    const signal = AbortSignal.any([context.controller.signal, disconnected.signal]);
    let release, suppliedDeadline, abortSupplied;
    try {
      const preview = url.searchParams.get('cacheOnly') === '1';
      if (preview && (!context.mediaCache || context.live || context.cacheOwner?.closed)) {
        response.writeHead(504, { 'Cache-Control': 'no-store' }).end(); return true;
      }
      if (resource.cachedMedia && context.mediaCache && !context.live) {
        if (preview) {
          await context.mediaCache.preview(resource.cachedMedia, request, response); return true;
        }
        await context.mediaCache.transfer(resource.cachedMedia.owner, resource.cachedMedia, {}, request, response, signal);
        return true;
      }
      if (resource.snapshot) {
        const snapshot = resource.snapshot;
        let content = this.rewrite(context, resource, snapshot.content, snapshot.url, snapshot.headers);
        if (preview) content = this.cacheOnlyPlaylist(content);
        const bytes = Buffer.from(content);
        response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'Content-Length': bytes.length, 'Cache-Control': 'no-store' });
        response.end(request.method === 'HEAD' ? undefined : bytes);
        return true;
      }
      if (preview) { response.writeHead(504, { 'Cache-Control': 'no-store' }).end(); return true; }
      const headers = new Headers(resource.headers);
      headers.set('accept-encoding', 'identity');
      headers.delete('range');
      headers.delete('if-range');
      if (!resource.playlist && typeof request.headers.range === 'string') {
        headers.set('range', request.headers.range);
        if (typeof request.headers['if-range'] === 'string') headers.set('if-range', request.headers['if-range']);
      }
      const upstream = suppliedUpstream || await this.fetch(context, resource, {
        headers, signal, timeoutMs: this.timeoutMs, method: request.method,
      });
      release = upstream.release;
      if (suppliedUpstream) {
        // MediaCache releases the fetch deadline to allow hour-long movies.
        // A reused playlist read still needs this proxy's bounded deadline,
        // and must stop when its HLS context or client is cancelled.
        abortSupplied = () => suppliedUpstream.controller.abort(signal.reason);
        signal.addEventListener('abort', abortSupplied, { once: true });
        if (signal.aborted) abortSupplied();
        suppliedDeadline = setTimeout(() => suppliedUpstream.controller.abort(), this.timeoutMs);
        suppliedDeadline.unref?.();
      }
      const remote = upstream.response;
      const outgoing = { 'Cache-Control': 'no-store' };
      for (const name of responseHeaders) if (remote.headers.has(name)) outgoing[name] = remote.headers.get(name);
      if (remote.headers.has('content-length') && !remote.headers.has('content-encoding'))
        outgoing['content-length'] = remote.headers.get('content-length');
      if (request.method === 'HEAD' || !remote.body) {
        // A transformed playlist has a different length from its origin.
        if (resource.playlist) delete outgoing['content-length'];
        response.writeHead(remote.status, outgoing).end();
        await remote.body?.cancel();
        return true;
      }
      const iterator = remote.body[Symbol.asyncIterator]();
      const prefix = [];
      let count = 0, next;
      do {
        next = await iterator.next();
        if (!next.done) {
          prefix.push(Buffer.from(next.value)); count += next.value.length;
          if (context.cacheOwner) context.cacheOwner.networkBytes += next.value.length;
        }
      } while (!next.done && count < 16);
      // Sniff the body as well as the declared media type. Some providers serve
      // extensionless HLS as application/octet-stream; keys remain binary.
      const playlist = remote.ok && Buffer.concat(prefix).toString('utf8', 0, 128).trimStart().startsWith('#EXTM3U');
      if (playlist) {
        const chunks = prefix;
        while (!next.done) {
          if (count > this.maxPlaylistBytes) throw new Error('HLS playlist exceeds the size limit');
          next = await iterator.next();
          if (!next.done) {
            chunks.push(Buffer.from(next.value)); count += next.value.length;
            if (context.cacheOwner) context.cacheOwner.networkBytes += next.value.length;
          }
        }
        if (count > this.maxPlaylistBytes) throw new Error('HLS playlist exceeds the size limit');
        const original = Buffer.concat(chunks).toString('utf8');
        // DEFINE/IMPORT bind variables to a playlist's original URI and parent.
        // Redirect the whole branch so the native HLS demuxer keeps that scope.
        if (/^#EXT-X-DEFINE:/m.test(original) || original.includes('{$')) {
          if (context.cacheOwner) context.cacheOwner.nativeFallback = true;
          response.writeHead(307, { Location: upstream.url, 'Cache-Control': 'no-store' }).end();
          return true;
        }
        // Cutting only one of separate audio/video/subtitle playlists moves it
        // off the others' timeline. Keep all branches intact until coordinated
        // cuts across renditions are supported; dependencies still use headers.
        if (original.split(/\r?\n/).some(line => line.startsWith('#EXT-X-MEDIA:') &&
            /[:,]TYPE=(?:AUDIO|VIDEO|SUBTITLES)(?:,|$)/.test(line) && /[:,]URI=/.test(line)))
          context.separateRenditions = true;
        if (/^#EXTINF:/m.test(original) && !/^#EXT-X-ENDLIST/m.test(original)) {
          context.live = true;
          if (context.cacheOwner) context.cacheOwner.nativeFallback = true;
        }
        if (context.mediaCache && !context.live) {
          // Keep only acquired finite playlists, bounded by the same memory cap
          // as a playlist read. Media blocks remain on disk, never in snapshots.
          const size = Buffer.byteLength(original);
          const before = resource.snapshot?.bytes || 0;
          if ((context.snapshotBytes || 0) - before + size <= this.maxPlaylistBytes) {
            context.snapshotBytes = (context.snapshotBytes || 0) - before + size;
            resource.snapshot = { content: original, url: upstream.url, headers: upstream.scopedHeaders, bytes: size };
          }
        }
        const bytes = Buffer.from(this.rewrite(context, resource, original, upstream.url, upstream.scopedHeaders));
        response.writeHead(remote.status, {
          'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'Content-Length': bytes.length,
          'Cache-Control': 'no-store',
        }).end(bytes);
      } else {
        response.writeHead(remote.status, outgoing);
        // Do not expose a transient segment EOF to FFmpeg's HLS demuxer: it
        // advances to the next segment on EOF, even when bytes are missing.
        // The client still receives the first prefix immediately; only a
        // validated, same-entity VOD Range can continue that response in place.
        const body = Readable.from(this.mediaBody(context, resource, upstream, iterator, prefix, next, headers, signal));
        await pipeline(body, response, { signal });
      }
    } catch {
      if (signal.aborted || response.headersSent) response.destroy();
      else response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }).end('播放资源读取失败，请重试或关闭 M3U8 去广告');
    } finally {
      clearTimeout(suppliedDeadline);
      if (abortSupplied) signal.removeEventListener('abort', abortSupplied);
      suppliedUpstream?.controller.abort();
      release?.();
      disconnected.abort();
      response.removeListener('close', onClose);
    }
    return true;
  }

  cacheOnlyPlaylist(content) {
    const prefix = `${this.baseUrl()}/hls/`;
    const mark = address => {
      if (!address.startsWith(prefix)) return address;
      const url = new URL(address); url.searchParams.set('cacheOnly', '1'); return url.href;
    };
    return content.split('\n').map(line => {
      if (!line.startsWith('#')) return mark(line);
      return line.replace(/([:,])URI="([^"]*)"/g, (_match, delimiter, address) => `${delimiter}URI="${mark(address)}"`);
    }).join('\n');
  }
}
