import { fetchBuffer } from './http.mjs';
import { AppError } from './errors.mjs';

// The source's on-demand SegmentBase MPD can make libavformat scan hours of
// fragmented MP4 before opening. Keep its authenticated, refreshable proxy
// tracks, but let mpv open each MP4 directly (including its own seek index).
// This recognizes one known source template, not arbitrary DASH manifests.
export async function prepareBilibiliDash(session, baseUrl, { signal, fetchBytes = fetchBuffer } = {}) {
  if (session.request?.siteKey !== 'nodejs_bili_all' || !baseUrl || session.isLive) return session;
  signal?.throwIfAborted();
  const qualities = await Promise.all(session.qualities.map(async quality => {
    let proxy;
    try {
      proxy = new URL(quality.url);
      if (proxy.origin !== new URL(baseUrl).origin || proxy.pathname !== '/spider/bili_all/3/proxy'
        || proxy.searchParams.get('do') !== 'mpd' || proxy.searchParams.get('mode') !== 'dash'
        || !/^[a-f0-9]{32}$/.test(proxy.searchParams.get('token') || '')
        || [...proxy.searchParams.keys()].some(key => !['do', 'mode', 'token'].includes(key))) return quality;
    } catch { return quality; }
    try {
      const xml = (await fetchBytes(proxy.href, { headers: quality.headers, signal,
        timeoutMs: 3000, maxBytes: 256 * 1024, label: '哔哩播放清单' })).toString('utf8');
      signal?.throwIfAborted();
      const prefix = `${proxy.origin}${proxy.pathname}/media/${proxy.searchParams.get('token')}`;
      const tracks = bilibiliProxyTracks(xml, prefix);
      return tracks ? { ...quality, url: tracks.video, audioUrl: tracks.audio || '', format: 'mp4' } : quality;
    } catch (error) {
      signal?.throwIfAborted();
      // An inspection failure must leave the original route and recovery path
      // available; it must not replace a working source with public API media.
      return quality;
    }
  }));
  signal?.throwIfAborted();
  session.qualities = qualities;
  return session;
}

function bilibiliProxyTracks(xml, prefix) {
  const document = /^\s*(?:<\?xml[^>]*\?>\s*)?<MPD\b([^>]*)>\s*<Period\b([^>]*)>([\s\S]*?)<\/Period>\s*<\/MPD>\s*$/.exec(xml);
  if (!document || !/\btype\s*=\s*["']static["']/.test(document[1])
    || /<!|\b(?:sourceURL|presentationTimeOffset)\s*=|<(?:SegmentList|SegmentTemplate|ContentProtection)\b/.test(xml)
    || document[2].replace(/\b(?:id\s*=\s*["'][^"']*["']|start\s*=\s*["']PT0S["'])/g, '').trim()) return null;
  const setPattern = /<AdaptationSet\b([^>]*)>([\s\S]*?)<\/AdaptationSet>/g;
  const sets = [...document[3].matchAll(setPattern)];
  if (sets.length < 1 || sets.length > 2
    || document[3].replace(setPattern, '').trim()) return null;
  const tracks = {};
  for (const [, attributes, body] of sets) {
    const kind = /\bmimeType=["'](video|audio)\/mp4["']/.exec(attributes)?.[1];
    const track = /^\s*<Representation\b[^>]*>\s*<BaseURL>\s*([^<]+?)\s*<\/BaseURL>\s*<SegmentBase\s+indexRange=["']\d+-\d+["']>\s*<Initialization\s+range=["']\d+-\d+["']\s*\/>\s*<\/SegmentBase>\s*<\/Representation>\s*$/.exec(body);
    const url = track?.[1];
    if (!kind || tracks[kind] || url !== `${prefix}/${kind}`) return null;
    tracks[kind] = url;
  }
  return tracks.video ? tracks : null;
}

// Recover only a failed Bilibili proxy. Working/authenticated source routes keep
// their own quality choices; the fallback uses the qualities the API grants.
export async function recoverBilibiliQuality(session, index, { signal, fetchBytes = fetchBuffer } = {}) {
  const identity = /^(BV[a-zA-Z0-9]+)_(\d+)_(\d+)(?:_|$)/.exec(session.request?.id || '');
  if (!/bili/i.test(session.request?.siteKey || '') || !identity)
    throw new AppError('PLAY_REPAIR_UNAVAILABLE', '当前线路不支持此播放恢复方式');
  const selected = session.qualities[index];
  if (!selected) throw new AppError('PLAY_REPAIR_UNAVAILABLE', '播放线路已改变');
  const endpoint = new URL('https://api.bilibili.com/x/player/playurl');
  for (const [key, value] of Object.entries({ bvid: identity[1], cid: identity[3], qn: '127', fnval: '4048', fnver: '0', fourk: '1' }))
    endpoint.searchParams.set(key, value);
  const headers = { ...selected.headers, Referer: `https://www.bilibili.com/video/${identity[1]}/` };
  const result = JSON.parse((await fetchBytes(endpoint.href, { headers, signal, timeoutMs: 12000,
    maxBytes: 2 * 1024 ** 2, label: '哔哩播放地址' })).toString('utf8'));
  if (result.code !== 0 || !result.data?.dash?.video?.length)
    throw new AppError('PLAY_REPAIR_UNAVAILABLE', '哔哩暂未返回可用视频，请稍后重试或在接口配置中检查登录状态');
  const dash = result.data.dash;
  const address = track => {
    const value = track?.baseUrl || track?.base_url;
    try {
      const url = new URL(value);
      if (!['http:', 'https:'].includes(url.protocol)) return '';
      // Some mcdn peers reset TLS on Range requests. The playurl response
      // already carries signed CDN mirrors of this exact representation; use
      // one during failed-proxy recovery, keeping its quality and credentials.
      if (url.hostname.endsWith('.mcdn.bilivideo.cn')) {
        const backups = [track.backupUrl, track.backup_url].flatMap(items => Array.isArray(items) ? items : []);
        for (const candidate of backups) {
          try {
            const backup = new URL(candidate);
            if (['http:', 'https:'].includes(backup.protocol) && !backup.username && !backup.password
              && backup.hostname.endsWith('.bilivideo.com')) return backup.href;
          } catch {}
        }
      }
      return url.href;
    } catch { return ''; }
  };
  const videos = dash.video.filter(track => address(track)).sort((a, b) => b.height - a.height
    || Number(/^avc/i.test(b.codecs)) - Number(/^avc/i.test(a.codecs)) || b.bandwidth - a.bandwidth);
  const audio = (dash.audio || []).filter(track => address(track)).sort((a, b) => b.bandwidth - a.bandwidth)[0];
  const video = videos[0];
  if (!video || !audio) throw new AppError('PLAY_REPAIR_UNAVAILABLE', '哔哩视频或音频地址暂不可用');
  return { name: `${video.height}P`, url: address(video), audioUrl: address(audio), headers, format: 'mp4' };
}
