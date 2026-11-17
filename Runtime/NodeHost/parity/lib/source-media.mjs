import { fetchBuffer } from './http.mjs';
import { AppError } from './errors.mjs';

const resolvedPrefix = 'wincat-resolved:';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36';
const httpUrl = (value, base) => {
  try {
    const url = new URL(value, base);
    return ['http:', 'https:'].includes(url.protocol) ? url.href : '';
  } catch { return ''; }
};

// Read data literals only. A provider's page must never execute inside the runtime.
export function extractPageMedia(html, base) {
  for (const match of html.matchAll(/["']?(m3u8|hls|file|videoUrl)["']?\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/gi)) {
    let value;
    try {
      value = match[2][0] === '"' ? JSON.parse(match[2])
        : match[2].slice(1, -1).replace(/\\\//g, '/').replace(/\\'/g, "'");
    } catch { continue; }
    const url = httpUrl(value.replace(/&amp;/g, '&'), base);
    if (url) return url;
  }
  for (const match of html.matchAll(/<(?:source|video)\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/gi)) {
    const url = httpUrl(match[1].replace(/&amp;/g, '&'), base);
    if (url) return url;
  }
  return '';
}

export function resolvedSourceMedia(id) {
  if (typeof id !== 'string' || !id.startsWith(resolvedPrefix)) return null;
  try {
    if (id.length > 32768) throw new Error();
    const media = JSON.parse(Buffer.from(id.slice(resolvedPrefix.length), 'base64url').toString('utf8'));
    if (!httpUrl(media.url)) throw new Error();
    return { url: media.url, header: media.header, format: media.format, parse: 0 };
  } catch { throw new AppError('PLAY_EMPTY', '播放地址已失效，请重新打开影片详情'); }
}

export async function repairSourceDetail(value, site, { id, signal, fetchBytes = fetchBuffer } = {}) {
  const vod = Array.isArray(value?.list) ? value.list[0] : value;
  if (!vod || !(/(?:^|_)avdb$/i.test(String(site?.key || '')) || /^avdb$/i.test(String(site?.name || '')))) return value;
  // Older Avdb sources return “播放$” after the embed page changes its schema.
  // Leave working source versions untouched.
  if (String(vod.vod_play_url || '').split('$$$').some(line => line.split('#').some(episode => {
    const separator = episode.indexOf('$');
    return (separator < 0 ? episode : episode.slice(separator + 1)).trim();
  }))) return value;
  const read = async (url, headers = {}) => (await fetchBytes(url, {
    headers: { 'User-Agent': userAgent, ...headers }, signal,
    maxBytes: 4 * 1024 ** 2, timeoutMs: 20000, label: '播放地址',
  })).toString('utf8');
  const detail = JSON.parse(await read(`https://avdbapi.com/api.php/provide/vod?ac=detail&ids=${encodeURIComponent(id || vod.vod_id)}`));
  const entries = detail?.list?.[0]?.episodes?.server_data;
  const episode = Object.values(entries || {}).flat().find(item => item?.link_embed || item?.link_m3u8);
  const embed = httpUrl(episode?.link_embed || '');
  let url = httpUrl(episode?.link_m3u8 || '');
  if (!url && embed) url = extractPageMedia(await read(embed, { Referer: 'https://avdbapi.com/' }), embed);
  if (!url) throw new AppError('PLAY_EMPTY', '该线路暂未提供可播放地址，请稍后重试或选择其他线路');
  const origin = new URL(embed || url).origin;
  const media = { url, header: { 'User-Agent': userAgent, Referer: `${origin}/`, Origin: origin }, format: 'm3u8' };
  const repaired = { ...vod, vod_play_from: vod.vod_play_from || 'Avdb',
    vod_play_url: `播放$${resolvedPrefix}${Buffer.from(JSON.stringify(media)).toString('base64url')}` };
  return Array.isArray(value?.list) ? { ...value, list: [repaired, ...value.list.slice(1)] } : repaired;
}

// A legacy cleaner rewraps already playable HLS and can fail on the first
// segment. Keep it as a fallback, and let mpv read the signed original directly.
export function originalHlsMedia(input, baseUrl) {
  if (!baseUrl) return '';
  try {
    const proxy = new URL(input);
    if (proxy.origin !== new URL(baseUrl).origin || !/\/m3u8-clean$/.test(proxy.pathname)) return '';
    const original = proxy.searchParams.get('url');
    return original && /^https?:\/\//i.test(original) && httpUrl(original) ? original : '';
  } catch { return ''; }
}
