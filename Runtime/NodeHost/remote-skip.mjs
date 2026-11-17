import { providerJson } from './parity/lib/provider-http.mjs';
import { skipPreferences } from './parity/lib/media-identity.mjs';

const finite = value => typeof value === 'number' && Number.isFinite(value);
function segment(kind, start, end, duration, source) {
  if (!finite(start) || !finite(end) || !finite(duration) || duration <= 0 || start < 0 || end <= start + (source === '手动' ? 0 : 1) ||
    end > duration + .5 || end - start > (source === '手动' ? 3600 : 600) || start >= duration) return null;
  return { kind, start, end: Math.min(end, duration), source };
}
function addSafeSegment(segments, row, duration) {
  if (segments.some(item => item.start < row.end && row.start < item.end)) return;
  if (segments.reduce((total, item) => total + item.end - item.start, row.end - row.start) >= duration) return;
  segments.push(row);
}

export function chapterSegments(chapters, duration) {
  if (!Array.isArray(chapters) || !finite(duration) || duration <= 0) return [];
  const rows = chapters.filter(row => row && finite(row.time) && row.time >= 0).slice(0, 2000).sort((a, b) => a.time - b.time);
  return rows.flatMap((row, index) => {
    const title = String(row.title || '').trim();
    const kind = /^(?:op|opening|intro|片头)(?:\s*\d+)?(?:\s*[-:：].*)?$/i.test(title) ? 'opening'
      : /^(?:ed|ending|outro|credits|end credits|片尾)(?:\s*\d+)?(?:\s*[-:：].*)?$/i.test(title) ? 'ending' : '';
    if (!kind || kind === 'opening' && row.time > Math.min(600, duration / 3) || kind === 'ending' && row.time < duration / 2) return [];
    const result = segment(kind, row.time, finite(row.end) ? row.end : rows[index + 1]?.time ?? duration, duration, '章节');
    return result ? [result] : [];
  });
}

export function providerSegments(data, duration, provider) {
  if (!data || typeof data !== 'object') return [];
  const reference = finite(data.duration_ms) ? data.duration_ms / 1000 : finite(data.runtime_ms) ? data.runtime_ms / 1000
    : finite(data.duration_sec) ? data.duration_sec : finite(data.runtime_sec) ? data.runtime_sec : 0;
  if (reference > 0 && Math.abs(reference - duration) > Math.max(30, duration * .1)) return [];
  const result = [];
  for (const [field, kind] of [['intro', 'opening'], [provider === 'theintrodb' ? 'credits' : 'outro', 'ending']]) {
    const rows = Array.isArray(data[field]) ? data[field] : data[field] ? [data[field]] : [];
    for (const row of rows.slice(0, 30)) {
      if (!row || typeof row !== 'object') continue;
      let start = finite(row.start_ms) ? row.start_ms / 1000 : row.start_sec;
      let end = finite(row.end_ms) ? row.end_ms / 1000 : row.end_sec;
      // TheIntroDB explicitly uses null for an opening at file start and
      // credits continuing to EOF. Missing or invalid numeric fields stay invalid.
      if (provider === 'theintrodb') {
        if (kind === 'opening' && row.start_ms === null) start = 0;
        if (kind === 'ending' && row.end_ms === null) end = reference > 0 ? reference : duration;
      }
      if (kind === 'ending' && reference > 0) {
        if (Math.abs(reference - duration) > Math.max(30, duration * .1)) continue;
        start += duration - reference; end += duration - reference;
      }
      const item = segment(kind, start, end, duration, provider === 'theintrodb' ? 'TheIntroDB' : 'IntroDB');
      if (item && (kind !== 'opening' || item.start <= Math.min(600, duration / 3)) &&
        (kind !== 'ending' || item.start >= duration / 2)) result.push(item);
    }
  }
  return result;
}

// Ported from the maintained MacCat reference; native identity resolution stays on Swift.
export class IntroSkip {
  constructor({ fetchJson = (url, signal) => providerJson(url, {
    signal, maxBytes: 512 * 1024, timeoutMs: 6000, label: '片头片尾信息',
  }) } = {}) { this.fetchJson = fetchJson; this.cache = new Map(); }
  async lookup(url, signal) {
    const key = String(url), cached = this.cache.get(key);
    if (cached && cached.expires > Date.now()) return cached.value;
    let value;
    try { value = await this.fetchJson(key, signal); }
    catch (error) {
      if (error.httpStatus !== 404) throw error;
      value = null; // A missing episode is a valid empty result, not an outage.
    }
    this.cache.set(key, { value, expires: Date.now() + 3600_000 });
    while (this.cache.size > 128) this.cache.delete(this.cache.keys().next().value);
    return value;
  }
  async plan(session, { duration, chapters = [] }, signal, resolveIdentity) {
    const preferences = skipPreferences(session.preferences);
    if (session.isLive || session.request?.isLive || session.request?.music || !finite(duration) || duration <= 0) return { segments: [], message: '需要时长已知的点播媒体' };
    const opening = preferences.openingOverride || 0, ending = preferences.endingOverride || 0;
    if (opening + ending >= duration) return { segments: [], message: '片头与片尾总时长不能覆盖正片' };
    const manual = [segment('opening', 0, opening, duration, '手动'), segment('ending', duration - ending, duration, duration, '手动')].filter(Boolean);
    const segments = [...manual];
    for (const row of chapterSegments(chapters, duration)) if (!manual.some(item => item.kind === row.kind)) addSafeSegment(segments, row, duration);
    segments.sort((a,b)=>a.start-b.start);
    if (segments.some(item => item.kind === 'opening') && segments.some(item => item.kind === 'ending')) return { segments };
    const { identity, metadata } = resolveIdentity ? await resolveIdentity(segments) : session;
    const tv = identity?.mediaType === 'tv';
    const known = identity && ['movie', 'tv'].includes(identity.mediaType) && Number.isSafeInteger(identity.tmdbId) && identity.tmdbId > 0 && (!tv || Number.isSafeInteger(identity.season) && identity.season > 0 && Number.isSafeInteger(identity.episode) && identity.episode > 0);
    if (!known) return { segments, message: segments.length ? '' : '未识别到片头片尾，可切换手动时长' };
    const requests = [];
    if (Number.isSafeInteger(identity.tmdbId) && identity.tmdbId > 0) {
      const url = new URL('https://api.theintrodb.org/v3/media');
      url.searchParams.set('tmdb_id', identity.tmdbId);
      if (tv) { url.searchParams.set('season', identity.season); url.searchParams.set('episode', identity.episode); }
      requests.push({ url, provider: 'theintrodb' });
    }
    const imdb = metadata?.imdbId || metadata?.externalIds?.imdb_id;
    if (tv && /^tt\d+$/.test(imdb || '')) {
      const url = new URL('https://api.introdb.app/segments');
      url.searchParams.set('imdb_id', imdb); url.searchParams.set('season', identity.season); url.searchParams.set('episode', identity.episode);
      requests.push({ url, provider: 'introdb' });
    }
    const results = await Promise.allSettled(requests.map(async request => {
      const data = await this.lookup(request.url, signal);
      // An incorrect provider/cache episode is never a usable match. Older responses omit these keys.
      if (data && ((data.tmdb_id !== undefined && Number(data.tmdb_id) !== identity.tmdbId) ||
        (data.imdb_id !== undefined && data.imdb_id !== imdb) ||
        (data.type !== undefined && data.type !== identity.mediaType) ||
        (data.media_type !== undefined && data.media_type !== identity.mediaType) ||
        (data.is_movie !== undefined && data.is_movie !== (identity.mediaType === 'movie')) ||
        (tv && ((data.season !== undefined && Number(data.season) !== identity.season) ||
          (data.episode !== undefined && Number(data.episode) !== identity.episode))))) return [];
      return providerSegments(data, duration, request.provider);
    }));
    if (signal?.aborted) throw signal.reason;
    for (const result of results) if (result.status === 'fulfilled') for (const row of result.value) {
      // Chapters from this exact media take precedence; overlapping providers do not cause double skips.
      if (segments.some(item => item.kind === row.kind && (['章节','手动'].includes(item.source) || item.start < row.end && row.start < item.end))) continue;
      addSafeSegment(segments, row, duration);
    }
    segments.sort((a, b) => a.start - b.start);
    const unavailable = results.some(result => result.status === 'rejected');
    const complete = segments.some(row => row.kind === 'opening') && segments.some(row => row.kind === 'ending');
    return { segments, retryable: unavailable && !complete,
      message: unavailable && !complete ? '在线片头片尾信息暂不可用，已保留本地或已匹配时间'
        : segments.length ? '' : '没有匹配的片头片尾数据，可使用手动时长' };
  }
}
