import { normalizePlayResult, normalizeHeaders } from './parity/lib/playback.mjs';
import { prepareBilibiliDash } from './parity/lib/bilibili-media.mjs';

// Keep the desktop normalizer intact. Mobile additionally carries companion
// track headers and the source's transport hints through the native boundary.
function payload(input) {
  let value = input;
  for (let depth = 0; depth < 4; depth++) {
    if (typeof value === 'string') {
      try { value = JSON.parse(value); } catch { return { url: value }; }
    }
    if (Array.isArray(value)) value = value[0];
    let nested;
    for (const name of ['data', 'result', 'play']) {
      let candidate = value?.[name];
      if (typeof candidate === 'string') {
        try { candidate = JSON.parse(candidate); } catch { continue; }
      }
      if (candidate && typeof candidate === 'object' && !Array.isArray(candidate)) { nested = candidate; break; }
    }
    if (!nested) break;
    // Remove consumed outer wrappers before merging: inner wrapper fields are
    // the next layer, not stale aliases of the layer already visited.
    const outer = { ...value };
    for (const name of ['data', 'result', 'play']) delete outer[name];
    value = { ...outer, ...nested };
  }
  return value || {};
}

export async function normalizeMobilePlayback(params, signal) {
  signal?.throwIfAborted();
  const raw = payload(params.result), extra = raw.extra || {};
  let baseURL = params.baseURL;
  // Bundle proxy origins differ from the control server and from the original
  // subscription URL. Recognize their own origin without rewriting signed URLs.
  const first = typeof raw.url === 'string' ? raw.url : Array.isArray(raw.url) ? raw.url.find(x => typeof x === 'string' && /^https?:/.test(x)) : '';
  try { const u = new URL(first); if (['127.0.0.1', 'localhost'].includes(u.hostname)) baseURL = u.origin; } catch {}
  const session = normalizePlayResult(raw, { baseUrl: baseURL, title: params.title, episodeName: params.episodeName, request: params.request });
  // The subscription's live route is known before an extensionless HTTP/FLV
  // dispatcher can enter playback.prepare and its finite-file cache.
  if (params.isLive === true || params.request?.isLive === true) session.isLive = true;
  const resolve = value => {
    if (!value) return '';
    const text = String(value).replace(/js2p:\/\/_WEB_/gi, baseURL || '');
    try { return new URL(text, baseURL).href; } catch { return ''; }
  };
  const candidates = [raw.url, raw.urls, raw.play_url, raw.link, raw.src, raw.m3u8].find(x => x != null && x !== '' && (!Array.isArray(x) || x.length));
  const objects = Array.isArray(candidates) ? candidates.filter(x => x && typeof x === 'object') : candidates && typeof candidates === 'object' ? [candidates] : [];
  const sharedAudio = resolve(raw.audio || raw.audioUrl || raw.audio_url || extra.audio || extra.audioUrl || extra.audio_url);
  session.qualities = session.qualities.map((quality, index) => {
    const item = objects[index] || {};
    const audioUrl = quality.audioUrl || resolve(item.audio || item.audioUrl || item.audio_url) || sharedAudio;
    const audioHeaders = { ...quality.headers, ...normalizeHeaders(raw.audioHeaders || raw.audio_header || extra.audioHeaders),
      ...normalizeHeaders(item.audioHeaders || item.audio_header) };
    return { ...quality, audioUrl, audioHeaders };
  });
  session.audioUrl = sharedAudio || session.audioUrl;
  const threads = Number(raw.threads ?? raw.thread ?? raw.threadCount ?? extra.threads ?? extra.thread);
  session.threadCount = Number.isSafeInteger(threads) && threads > 0 ? threads : null;
  session.proxy = typeof raw.proxy === 'string' ? raw.proxy : typeof extra.proxy === 'string' ? extra.proxy : '';
  await prepareBilibiliDash(session, baseURL, { signal });
  signal?.throwIfAborted();
  return session;
}
