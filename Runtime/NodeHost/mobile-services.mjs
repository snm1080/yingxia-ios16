import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, randomBytes } from 'node:crypto';
import { HomeLibrary } from './parity/lib/home-library.mjs';
import { PanLinkChecker } from './parity/lib/pan-link-checker.mjs';
import { LiveDanmakuService } from './parity/lib/live-danmaku.mjs';
import { normalizeLiveDanmaku } from './parity/lib/live-danmaku-config.mjs';
import { parseDanmaku, decodeDanmaku, readCachedDanmaku, cacheDanmakuDocument } from './parity/lib/danmaku.mjs';
import { writeDanmakuIndex } from './parity/lib/danmaku-index.mjs';
import { fetchBuffer } from './parity/lib/http.mjs';
import { AISubtitleService } from './parity/lib/ai-subtitles.mjs';
import { OnlineSubtitles } from './parity/lib/online-subtitles.mjs';
import { HlsProxy } from './parity/lib/hls-proxy.mjs';
import { MediaCache } from './parity/lib/media-cache.mjs';
import { DashCache } from './parity/lib/dash-cache.mjs';
import { panSearchDefaults, normalizePanOptions } from './parity/lib/pan-search-options.mjs';
import { normalizeMobilePlayback } from './mobile-playback.mjs';
import { segmentedMP4Index, segmentedRepresentation } from './segmented-mp4.mjs';
import { fetchTMDB } from './tmdb-transport.mjs';
import { IntroSkip } from './remote-skip.mjs';

const defaults = {
  tmdb: { panApiBase: 'https://so.252035.xyz', panToken: '', ...panSearchDefaults },
  subtitles: { xunlei: true, shooter: true, assrt: true, subtitlecat: false, subhd: false, language: 'zh', assrtToken: '' },
  ai: { enabled: false, endpoint: '', protocol: 'chat', model: '', apiKey: '', targetLanguage: 'zh-CN', transcriptionEndpoint: '', transcriptionModel: 'whisper-1', transcriptionApiKey: '', transcriptionProtocol: 'transcription', transcriptionUseTranslation: false },
};

/// The danmaku comment fetch mirrors the Swift transports' shared policy
/// (DanmakuRetry in TVCore): up to two retries, about 1 s then 3 s apart,
/// when the failure is transient - a network error, a timeout, an
/// interrupted download, or HTTP 5xx. A deterministic refusal (4xx,
/// oversize, redirect problems) or a caller cancellation throws at once.
/// Only the danmaku.prepare call site wraps fetchBuffer this way; the
/// helper's global semantics are unchanged for every other consumer.
const danmakuFetchBackoffsMs = [1000, 3000];
function danmakuFetchIsTransient(error, signal) {
  if (signal?.aborted) return false;
  if (typeof error?.httpStatus === 'number') return error.httpStatus >= 500 && error.httpStatus < 600;
  return ['NETWORK_ERROR', 'REQUEST_ABORTED', 'DOWNLOAD_INTERRUPTED'].includes(error?.code);
}
async function fetchDanmakuBuffer(url, options) {
  let retries = 0;
  for (;;) {
    try { return await fetchBuffer(url, options); }
    catch (error) {
      if (retries >= danmakuFetchBackoffsMs.length || !danmakuFetchIsTransient(error, options.signal)) throw error;
      // The backoff honours the caller's cancellation too: a fetch the
      // viewer has already switched away from ends with its original
      // error instead of sleeping out the wait and firing one more
      // request nobody is waiting for.
      await new Promise(resolve => {
        if (options.signal?.aborted) return resolve();
        const timer = setTimeout(resolve, danmakuFetchBackoffsMs[retries++]);
        options.signal?.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true });
      });
      if (options.signal?.aborted) throw error;
    }
  }
}

/// Shared portable business logic runs inside the already embedded Node, never a desktop child process.
export class MobileServices {
  constructor(directory, baseURL) {
    this.directory = directory;
    this.configuration = structuredClone(defaults); this.revision = 0;
    this.settings = { private: async () => ({ ...this.configuration, revision: this.revision }) };
    this.session = null; this.events = []; this.document = null; this.danmakuRevision = 0; this.operations = new Map();
    this.home = new HomeLibrary(null, this.settings);
    this.checker = new PanLinkChecker(this.settings);
    this.live = new LiveDanmakuService((type, value) => {
      this.events.push({ type, value }); if (this.events.length > 32) this.events.shift();
    });
    this.ai = new AISubtitleService(this.settings, () => this.session);
    this.subtitles = new OnlineSubtitles(directory, this.settings, () => this.session);
    this.hls = new HlsProxy({ baseUrl: baseURL });
    this.cache = new MediaCache({ dataDirectory: directory, baseUrl: baseURL });
    this.dashCache = new DashCache({ baseURL, cache: this.cache });
    this.cache.handleManifest = async (resource, request, response, upstream, preview = false) => {
      if (!resource.manifestURL) {
        const address = upstream.url, headers = upstream.scopedHeaders || upstream.headers || resource.headers;
        if (/dash\+xml/i.test(upstream.response.headers.get('content-type') || '')) {
          resource.manifestURL = this.dashCache.prepare(resource.owner.id, address, headers, resource.owner);
          resource.manifestKind = 'dash';
        } else {
          const prepared = this.hls.prepare({ id: resource.owner.id, qualities: [{ url: address, headers, format: 'm3u8' }] },
            { enabled: resource.adClean === true, forceProxy: true, mediaCache: this.cache, cacheOwner: resource.owner });
          resource.manifestURL = prepared.qualities[0].url; resource.manifestKind = 'hls';
        }
      }
      const address = new URL(resource.manifestURL);
      if (preview) address.searchParams.set('cacheOnly','1');
      if (resource.manifestKind === 'hls') await this.hls.handle(request, response, address, upstream);
      else {
        // A DASH snapshot follows its own XML addressing rules. Close the
        // initial probe before the snapshot fetch instead of holding two reads.
        upstream?.controller.abort(); await upstream?.response.body?.cancel().catch(() => {}); upstream?.releaseBudget?.();
        await this.dashCache.handle(request, response, address);
      }
    };
    this.baseURL = typeof baseURL === 'function' ? baseURL : () => baseURL;
    this.playbackManifests = new Map();
    this.introSkip = new IntroSkip();
  }

  assertSession(params) {
    if (!this.session || params.sessionId !== this.session.id) throw new Error('播放媒体已改变');
    return this.session;
  }
  async call(method, params = {}, signal) {
    switch (method) {
      case 'intro.plan': {
        const session = this.assertSession(params);
        if (params.mediaVersion !== session.mediaVersion) throw new Error('播放媒体已改变');
        const result = await this.introSkip.plan({ isLive: session.isLive, request: session.request,
          identity: params.identity, metadata: params.metadata, preferences: params.preferences }, params, signal);
        signal?.throwIfAborted();
        if (this.session !== session || params.mediaVersion !== session.mediaVersion) throw new Error('播放媒体已改变');
        return result;
      }
      case 'tmdb.fetch': return await fetchTMDB(params, signal);
      case 'playback.normalize': return await normalizeMobilePlayback(params, signal);
      case 'playback.prepare': {
        signal?.throwIfAborted();
        const id = params.id || randomUUID(), url = String(params.url || '');
        if (params.audioUrl && !/^https?:\/\//i.test(url)) throw new Error('当前分离音轨需要 HTTP/HTTPS 视频地址，请选择其他线路');
        if (!/^https?:\/\//i.test(url)) return { url, headers: params.headers || {} };
        const audio = /^https?:\/\//i.test(params.audioUrl || '') ? params.audioUrl : '';
        if (params.isLive === true && audio) throw new Error('当前直播带有分离音轨，请选择完整音视频线路');
        const format = String(params.format || '').toLowerCase();
        const knownFile = /^(?:mp4|m4v|mov|mkv|avi|flv|webm|ts|m2ts|mp3|m4a|aac|flac|wav|ogg|opus|wma|aiff|ape)$/.test(format)
          || /\.(?:mp4|m4v|mov|mkv|avi|flv|webm|ts|m2ts|mp3|m4a|aac|flac|wav|ogg|opus|wma|aiff|ape)$/i.test(new URL(url).pathname);
        const hls = format === 'm3u8' || /\.m3u8(?:[?#]|$)/i.test(url);
        if (audio && (hls || format === 'mpd' || /\.mpd(?:[?#]|$)/i.test(url))) throw new Error('当前播放清单另带分离音轨，暂不支持此组合，请选择完整音视频线路');
        if (hls && (params.adClean === true || params.enabled === true && params.isLive !== true)) {
          const owner = params.enabled === true && params.isLive !== true ? this.cache.createSession(id,
            { enabled: true, sizeGB: Math.max(1, Math.min(4, Number(params.sizeGB) || 1)) }) : null;
          const prepared = this.hls.prepare({ id, isLive: params.isLive === true,
            qualities: [{ url, headers: params.headers || {}, format: 'm3u8' }] },
            { enabled: params.adClean === true, forceProxy: !!owner, mediaCache: this.cache, cacheOwner: owner }).qualities[0];
          return { ...prepared, ownerID: id };
        }
        if ((format === 'mpd' || /\.mpd(?:[?#]|$)/i.test(url)) && params.enabled === true && params.isLive !== true) {
          const owner = this.cache.createSession(id, { enabled: true, sizeGB: Math.max(1, Math.min(4, Number(params.sizeGB) || 1)) });
          const cacheUrl = this.dashCache.prepare(id, url, params.headers || {}, owner);
          return { url, headers: params.headers || {}, cacheUrl, ownerID: id };
        }
        if (hls || format === 'mpd' || /\.mpd(?:[?#]|$)/i.test(url)) return { url, headers: params.headers || {} };
        if (params.isLive === true) return { url, headers: params.headers || {} };
        // KSPlayer opens native inputs independently. Keep their original
        // addresses/headers as demux identities; optional cache endpoints only
        // transport the same bytes through FFmpeg's IO callback.
        if (params.nativeTracks === true) {
          const original = { url, headers: params.headers || {},
            ...(audio ? { audioUrl: audio, audioHeaders: params.audioHeaders || params.headers || {} } : {}) };
          if (params.enabled !== true) return original;
          const owner = this.cache.createSession(id, { enabled: true,
            sizeGB: Math.max(1, Math.min(4, Number(params.sizeGB) || 1)) });
          const video = this.cache.resource(owner, url, params.headers || {});
          video.forwardCache = true;
          video.adClean = params.adClean === true;
          video.sniffManifest = !knownFile;
          const cacheUrl = this.cache.url(video, format || 'mp4');
          const sound = audio ? this.cache.resource(owner, audio, params.audioHeaders || params.headers || {}) : null;
          if (sound) sound.forwardCache = true;
          return { ...original, cacheUrl, ...(sound ? { audioCacheUrl: this.cache.url(sound, 'm4a') } : {}), ownerID: id };
        }
        if (!audio && params.enabled !== true) return { url, headers: params.headers || {} };
        const owner = this.cache.createSession(id, { enabled: params.enabled === true,
          sizeGB: Math.max(1, Math.min(4, Number(params.sizeGB) || 1)) });
        const video = this.cache.resource(owner, url, params.headers || {});
        video.forwardCache = true;
        video.adClean = params.adClean === true;
        video.sniffManifest = !knownFile;
        const videoURL = this.cache.url(video, format || 'mp4');
        if (!audio) return { url: videoURL, originalUrl: url, headers: {}, ownerID: id };
        const sound = this.cache.resource(owner, audio, params.audioHeaders || params.headers || {});
        sound.forwardCache = true;
        const audioURL = this.cache.url(sound, 'm4a');
        const token = randomBytes(24).toString('hex');
        // libavformat auto-detection requires a DASH profile in the MPD.
        // DASH demuxer probes the complete MP4 resources directly. The loopback
        // routes independently apply the two tracks' headers and preserve Range.
        const xml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
        let source = {};
        try { source = typeof params.resultJSON === 'string' ? JSON.parse(params.resultJSON) : {}; } catch {}
        for (let depth = 0; depth < 4; depth++) {
          let nested = source?.data ?? source?.result ?? source?.play;
          if (typeof nested === 'string') { try { nested = JSON.parse(nested); } catch { break; } }
          if (!nested || typeof nested !== 'object' || Array.isArray(nested)) break;
          source = nested;
        }
        // Bilibili returns total seconds in extra.duration. Native channel copies
        // already carry that raw reply; preserve it when assembling split tracks.
        const seconds = [params.duration, source?.duration, source?.extra?.duration]
          .map(Number).find(value => Number.isFinite(value) && value > 0);
        const duration = Number.isFinite(seconds) && seconds > 0 ? ` mediaPresentationDuration="PT${seconds}S"` : '';
        let videoIndex, audioIndex;
        try {
          [videoIndex, audioIndex] = await Promise.all([
            segmentedMP4Index(url, params.headers || {}, signal, seconds),
            segmentedMP4Index(audio, params.audioHeaders || params.headers || {}, signal, seconds),
          ]);
          signal?.throwIfAborted();
        } catch (error) { await this.cache.release(id); throw error; }
        const representation = (index, address, id, mime, bandwidth) => index
          ? segmentedRepresentation(index, address, id, mime, bandwidth, xml)
          : `<AdaptationSet contentType="${id}" mimeType="${mime}"><Representation id="${id}" bandwidth="${bandwidth}"><BaseURL>${xml(address)}</BaseURL></Representation></AdaptationSet>`;
        const manifest = `<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" minBufferTime="PT2S"${duration}><Period>${representation(videoIndex, videoURL, 'video', 'video/mp4', 10000000)}${representation(audioIndex, audioURL, 'audio', 'audio/mp4', 256000)}</Period></MPD>`;
        const cacheOnlyManifest = manifest.replaceAll(xml(videoURL), xml(`${videoURL}?cacheOnly=1`))
          .replaceAll(xml(audioURL), xml(`${audioURL}?cacheOnly=1`));
        this.playbackManifests.set(token, { id, manifest, cacheOnlyManifest });
        return { url: `${this.baseURL()}/playback/${token}.mpd`, headers: {}, ownerID: id, originalUrl: url, audioUrl: audio,
          indexedTracks: { video: !!videoIndex, audio: !!audioIndex } };
      }
      case 'playback.release': {
        for (const [key, value] of this.playbackManifests) if (value.id === params.id) this.playbackManifests.delete(key);
        this.hls.release(params.id); this.dashCache.release(params.id); await this.cache.release(params.id); return { released: true };
      }
      case 'playback.cache.stats': return params.id ? this.cache.statistics(params.id) : this.cache.videoStatistics();
      case 'playback.cache.clear': {
        await this.cache.clearVideos();
        this.dashCache.clear();
        for (const context of this.hls.contexts.values()) {
          if (!context.mediaCache || context.live) continue;
          context.snapshotBytes = 0;
          for (const resource of context.resources.values()) delete resource.snapshot;
        }
        return this.cache.videoStatistics();
      }
      case 'playback.prefetch': {
        const owner = this.cache.owners.get(params.id);
        if (!owner || owner.closed || !owner.enabled) return { bytes: 0 };
        const combined = signal ? AbortSignal.any([signal, owner.controller.signal]) : owner.controller.signal;
        const resources = [...owner.resources.values()];
        const maximum = Math.max(1024, Math.min(15 * 1024 ** 2, Number(params.maxBytes) || 15 * 1024 ** 2));
        let received = 0;
        // Source proxies may already fan out each Range request. Warm tracks
        // sequentially, using the same per-resource request budget as playback.
        for (let index = 0; index < resources.length; index++) {
          combined.throwIfAborted();
          const resource = resources[index];
          const budget = index === 0 ? maximum - (resources.length > 1 ? Math.min(512 * 1024, Math.floor(maximum / 8)) : 0) : Math.min(maximum - received,512 * 1024);
          if (budget <= 0) break;
          const limit = resource.meta?.total ? Math.min(budget,resource.meta.total) : budget;
          if (this.cache.covers(resource,0,limit-1)) { received += limit; continue; }
          let upstream;
          try {
            upstream=await this.cache.open(resource,'GET',`bytes=0-${limit-1}`,'',combined);
            const meta=this.cache.accept(resource,upstream.response);
            if (upstream.response.status !== 206 || !meta || meta.start !== 0) continue;
            for await (const data of this.cache.body(resource,upstream,meta,combined,limit)) received+=data.length;
          } finally {
            upstream?.controller.abort();await upstream?.response.body?.cancel().catch(()=>{});upstream?.releaseBudget?.();
          }
        }
        await this.cache.tail;
        return { bytes:received };
      }
      case 'settings.set': {
        if (params.videoCache) await this.cache.update(params.videoCache);
        if (params.tmdb) {
          const config = { ...defaults.tmdb, ...params.tmdb };
          const url = new URL(config.panApiBase);
          if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || /[\r\n\0]/.test(config.panToken || '')) throw new Error('盘搜地址或令牌无效');
          params = { ...params, tmdb: { ...config, ...normalizePanOptions(config) } };
        }
        for (const key of Object.keys(defaults)) if (params[key] && typeof params[key] === 'object')
          this.configuration[key] = { ...defaults[key], ...params[key] };
        this.revision++; return { revision: this.revision };
      }
      case 'operation.cancel': this.operations.get(params.id)?.abort(); return { cancelled: true };
      case 'session.set': {
        if (typeof params.id !== 'string' || !params.id || params.id.length > 128) throw new Error('播放会话无效');
        let retired;
        if (this.session?.id !== params.id || this.session?.mediaVersion !== params.mediaVersion) {
          this.danmakuRevision++; this.ai.cancel(); this.subtitles.cancel(); this.live.close(); this.events = [];
          retired = this.document; this.document = null;
        }
        const next = { ...params, mediaVersion: Number(params.mediaVersion) || 0, timelineVersion: Number(params.timelineVersion) || 0 };
        if (this.session?.id === next.id && this.session.mediaVersion === next.mediaVersion && this.session.timelineVersion !== next.timelineVersion)
          this.ai.cancel();
        if (this.session?.id === next.id && this.session.mediaVersion === next.mediaVersion) Object.assign(this.session, next);
        else this.session = next;
        if (retired) await fs.rm(retired.file, { force: true });
        return { ready: true };
      }
      case 'session.stop': {
        let retired;
        if (this.session?.id === params.sessionId) {
          this.ai.cancel(); this.subtitles.cancel(); this.live.close(); this.danmakuRevision++;
          retired = this.document; this.document = null; this.session = null; this.events = [];
        }
        this.hls.release(params.sessionId);
        if (retired) await fs.rm(retired.file, { force: true });
        return { stopped: true };
      }
      case 'pan.search': return await this.home.search(params, signal);
      case 'pan.check': return await this.checker.check(params, signal, { enabled: params.manual === true ? true : undefined });
      case 'live.start': {
        const session = this.assertSession(params), config = normalizeLiveDanmaku(params.descriptor, params.baseURL);
        if (!config) throw new Error('实时弹幕配置无效');
        this.live.update({ ...session, liveDanmaku: config }, params.enabled !== false); return { ready: true };
      }
      case 'live.stop': {
        const session = this.assertSession(params);
        if (params.mediaVersion !== undefined && params.mediaVersion !== session.mediaVersion) throw new Error('播放媒体已改变');
        this.live.close(); this.events = []; return { stopped: true };
      }
      case 'live.poll': this.assertSession(params); return { events: this.events.splice(0, 32) };
      case 'danmaku.prepare': {
        const session = this.assertSession(params);
        const revision = ++this.danmakuRevision;
        const cacheDirectory = path.join(this.directory, 'danmaku-cache');
        let text;
        if (params.cacheId !== undefined) {
          text = await readCachedDanmaku(cacheDirectory, params.cacheId);
          if (text === null) throw new Error('原弹幕缓存已失效');
        } else if (typeof params.text === 'string') {
          if (Buffer.byteLength(params.text) > 32 * 1024 ** 2) throw new Error('弹幕文件过大');
          text = params.text;
        } else if (typeof params.data === 'string') {
          if (params.data.length > 44 * 1024 ** 2) throw new Error('弹幕文件过大');
          text = decodeDanmaku(Buffer.from(params.data, 'base64'));
        } else {
          if (!/^https?:\/\//i.test(params.url || '')) throw new Error('弹幕地址无效');
          let contentType = '';
          const bytes = await fetchDanmakuBuffer(params.url, { signal, maxBytes: 32 * 1024 ** 2, timeoutMs: 45000, headers: params.headers || {},
            onResponse: response => { contentType = response.headers.get('content-type') || ''; } });
          text = decodeDanmaku(bytes, contentType);
        }
        let comments;
        try {
          comments = parseDanmaku(text);
        } catch (error) {
          // parseDanmaku throws DANMAKU_EMPTY for a well-formed document
          // that simply contains no comments. At this call site that is a
          // legitimate answer - "this episode has no danmaku" - not a
          // fetch failure, so let it through as an empty list and return
          // count 0 below. The parser itself keeps throwing: its other
          // caller (cache/file loading) treats an empty document as
          // unusable there. Genuine format errors still throw.
          if (error?.code !== 'DANMAKU_EMPTY') throw error;
          comments = [];
        }
        signal?.throwIfAborted(); if (this.session !== session || revision !== this.danmakuRevision) throw new Error('播放媒体或弹幕选择已改变');
        await fs.mkdir(this.directory, { recursive: true });
        const file = path.join(this.directory, 'danmaku-' + randomUUID() + '.index');
        const manifest = await writeDanmakuIndex(file, comments, { signal });
        const headerFile = await fs.open(file); const bytes = Buffer.alloc(Math.min(1024 * 1024 + 1, (await headerFile.stat()).size));
        await headerFile.read(bytes, 0, bytes.length, 0); await headerFile.close();
        const headerLength = bytes.indexOf(10) + 1;
        if (!headerLength) { await fs.rm(file, { force: true }); throw new Error('弹幕索引无效'); }
        if (this.session !== session || signal?.aborted || revision !== this.danmakuRevision) { await fs.rm(file, { force: true }); throw new Error('弹幕操作已取消'); }
        // Keep a bounded index of long declarative events; their start may lie before the normal time window.
        const longEvents = comments.filter(item => ['bas', 'positioned'].includes(item.effect?.kind)
          && Math.max(Number(item.effect?.lifetime) || 0, ...(item.effect?.items || []).map(node => Number(node.lifetime) || 0)) > 32);
        const previous = this.document; this.document = { file, manifest, headerLength, sessionId: session.id, longEvents };
        if (previous) await fs.rm(previous.file, { force: true });
        // Preserve the complete original document, including advanced effects,
        // separately from the session index that is deleted on playback close.
        const cacheId = params.cacheId ?? await cacheDanmakuDocument(cacheDirectory, text).catch(() => undefined);
        signal?.throwIfAborted();
        if (this.session !== session || revision !== this.danmakuRevision) throw new Error('播放媒体或弹幕选择已改变');
        return { count: manifest.count, chunks: manifest.chunks.length, ...(cacheId ? { cacheId } : {}) };
      }
      case 'danmaku.window': {
        this.assertSession(params);
        const document = this.document; if (!document) return { items: [], count: 0 };
        // 8 seconds / the minimum 0.25 scrolling speed = 32 seconds. A seek
        // must retain every still-visible ordinary cue as well as long effects.
        const position = Math.max(0, Number(params.position) || 0);
        const start = Math.max(0, position - 32), end = position + Math.min(120, Math.max(20, Number(params.duration) || 60));
        const chunks = document.manifest.chunks.filter(x => x.end >= start && x.time <= end);
        const file = await fs.open(document.file); const items = [];
        let retainedBytes = 0;
        try {
          for (const chunk of chunks) {
            if (items.length + chunk.count > 13000 || retainedBytes + chunk.bytes > 16 * 1024 ** 2)
              throw new Error('当前时间段弹幕过于密集，超过安全窗口预算；未截断弹幕');
            retainedBytes += chunk.bytes;
            signal?.throwIfAborted(); const buffer = Buffer.alloc(chunk.bytes);
            await file.read(buffer, 0, chunk.bytes, document.headerLength + chunk.offset);
            items.push(...JSON.parse(buffer.toString()).filter(x => x.time >= start && x.time <= end));
          }
        } finally { await file.close(); }
        for (const event of document.longEvents || []) {
          const lifetime = Math.max(Number(event.effect?.lifetime) || 0, ...(event.effect?.items || []).map(item => Number(item.lifetime) || 0));
          if (event.time < start && event.time + lifetime >= start) items.push(event);
        }
        items.sort((a, b) => a.time - b.time);
        if (items.length > 10000) throw new Error('当前时间段弹幕超过 10000 条；未截断弹幕');
        this.assertSession(params); return { items, count: document.manifest.count };
      }
      case 'subtitle.search': return await this.subtitles.search(params, signal);
      case 'subtitle.files': return await this.subtitles.files(params, signal);
      case 'subtitle.download': return await this.subtitles.download(params, signal);
      case 'subtitle.list': return await this.subtitles.list(params);
      case 'subtitle.delete': return await this.subtitles.remove(params);
      case 'subtitle.asset': {
        const asset = await this.subtitles.asset(params);
        return { id: asset.id, name: asset.name, data: (await fs.readFile(asset.path)).toString('base64') };
      }
      case 'ai.translate': return await this.ai.translate(params, signal);
      case 'ai.transcribe': return await this.ai.transcribe(params, signal);
      case 'ai.test': return await this.ai.test(params, signal);
      case 'hls.prepare': {
        const session = { id: params.id || randomUUID(), isLive: params.isLive === true, qualities: [{ url: params.url, headers: params.headers || {}, format: params.format || 'm3u8' }] };
        return this.hls.prepare(session, { enabled: params.enabled === true }).qualities[0];
      }
      case 'cache.prepare': {
        const format = String(params.format || '').toLowerCase();
        if (params.enabled !== true || params.isLive === true || /^(?:m3u8|mpd|application\/dash\+xml)$/.test(format)
          || /\.(?:m3u8|mpd)(?:[?#]|$)/i.test(params.url || '') || !/^https?:\/\//i.test(params.url || '')) return { url: params.url };
        const owner = this.cache.createSession(params.id, { enabled: true, sizeGB: Math.max(1, Math.min(4, Number(params.sizeGB) || 1)) });
        const resource = this.cache.resource(owner, params.url, params.headers || {});
        return { url: this.cache.url(resource, params.format || ''), originalUrl: params.url };
      }
      case 'cache.stats': return this.cache.statistics(params.id);
      case 'cache.release': await this.cache.release(params.id); return { released: true };
      case 'hls.release': this.hls.release(params.id); return { released: true };
      default: throw new Error('未知媒体服务');
    }
  }
  async dispatch(method, params, operationId) {
    const controller = new AbortController();
    if (operationId) { this.operations.get(operationId)?.abort(); this.operations.set(operationId, controller); }
    try { return await this.call(method, params, controller.signal); }
    finally { if (this.operations.get(operationId) === controller) this.operations.delete(operationId); }
  }
  async handle(request, response) {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname.startsWith('/playback/')) {
      const token = /^\/playback\/([a-f0-9]{48})\.mpd$/.exec(url.pathname)?.[1];
      const stored = token && this.playbackManifests.get(token);
      if (!stored || !['GET','HEAD'].includes(request.method)) return response.writeHead(404).end();
      const manifest = url.searchParams.get('cacheOnly') === '1' ? stored.cacheOnlyManifest : stored.manifest;
      response.writeHead(200, { 'Content-Type': 'application/dash+xml', 'Content-Length': Buffer.byteLength(manifest), 'Cache-Control': 'no-store' });
      response.end(request.method === 'HEAD' ? undefined : manifest); return;
    }
    if (url.pathname.startsWith('/media-cache/')) return await this.cache.handle(request, response, url);
    if (url.pathname.startsWith('/dash-cache/')) return await this.dashCache.handle(request, response, url);
    if (!url.pathname.startsWith('/hls/')) return false;
    return await this.hls.handle(request, response, url);
  }
  async close() { this.live.close(); this.ai.cancel(); this.subtitles.cancel(); this.hls.close(); this.dashCache.close(); this.playbackManifests.clear(); for (const job of this.operations.values()) job.abort(); await this.cache.close(); }
}
