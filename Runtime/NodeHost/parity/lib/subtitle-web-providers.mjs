import { fetchBuffer } from './http.mjs';
import { AppError } from './errors.mjs';

const headers = { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36' };
const text = value => String(value).replace(/<[^>]*>/g, ' ').replace(/&#(x[\da-f]+|\d+);/gi, (_, number) => {
  const point = number[0].toLowerCase() === 'x' ? parseInt(number.slice(1), 16) : Number(number);
  return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : '';
}).replace(/&(amp|lt|gt|quot|apos|nbsp);/gi, (_, name) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' })[name.toLowerCase()]).replace(/\s+/g, ' ').trim();
const anchors = html => Array.from(html.matchAll(/<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi), match => ({ href: text(match[1]), name: text(match[2]) }));
async function page(url, signal) {
  const bytes = await fetchBuffer(url, { maxBytes: 2 * 1024 * 1024, timeoutMs: 12000, signal, headers, label: '字幕页面' });
  return bytes.toString('utf8');
}
export async function searchSubtitleWebsite(provider, base, query, signal) {
  const origin = new URL(base), address = new URL(provider === 'subtitlecat' ? '/index.php' : '/search/' + encodeURIComponent(query), origin);
  if (provider === 'subtitlecat') address.searchParams.set('search', query);
  const html = await page(address.href, signal), results = new Map();
  for (const link of anchors(html)) {
    const url = new URL(link.href, address);
    if (url.origin !== origin.origin || !(provider === 'subtitlecat' ? /^\/subs\/\d+\/.+\.html$/i : /^\/a\/[a-z0-9]+$/i).test(url.pathname)) continue;
    if (results.has(url.href)) {
      if (provider === 'subhd' && link.name && !results.get(url.href).name.includes(link.name)) results.get(url.href).name += ' · ' + link.name;
      continue;
    }
    results.set(url.href, { name: link.name || query, url: url.href, format: provider === 'subhd' ? '字幕包' : 'srt',
      language: provider === 'subtitlecat' ? '多语言' : '', pageUrl: url.href });
    if (results.size >= 60) break;
  }
  if (!results.size && /captcha|turnstile|just a moment|验证您|人机验证/i.test(html)) throw new AppError('SUBTITLE_PROVIDER', '该字幕站需要浏览器验证，请在网站打开后重试');
  return [...results.values()];
}
export async function subtitleCatDownload(address, language, signal) {
  const base = new URL(address), html = await page(address, signal);
  const links = anchors(html).flatMap(link => {
    const url = new URL(link.href, base);
    if (url.origin !== base.origin || !/^\/subs\/\d+\/.+\.srt$/i.test(url.pathname)) return [];
    const name = decodeURIComponent(url.pathname.split('/').at(-1));
    const code = name.match(/-([a-z]{2,3}(?:-[a-z]{2,4})?)\.srt$/i)?.[1]?.toLowerCase() || '';
    const wanted = String(language || 'zh').toLowerCase();
    const score = code === wanted ? 100 : wanted.startsWith('zh') && code === 'zh-cn' ? 95
      : wanted.startsWith('zh') && code === 'zh-tw' ? 90 : code.split('-')[0] === wanted.split('-')[0] ? 80 : code === 'en' ? 10 : 0;
    return [{ url: url.href, name, score, format: 'srt' }];
  }).sort((a, b) => b.score - a.score);
  if (!links.length) throw new AppError('SUBTITLE_MISSING', '此页面暂未提供可直接下载的字幕，请选择其他结果');
  return [links[0]];
}

export async function subHDDownload(address, signal) {
  const base = new URL(address), sid = base.pathname.match(/^\/a\/([a-z0-9]+)$/i)?.[1];
  if (!sid || !['http:', 'https:'].includes(base.protocol) || base.username || base.password)
    throw new AppError('SUBTITLE_URL', 'SubHD 字幕页面无效');
  // The preparation cookie belongs to this single download, never to the
  // subtitle CDN, a different search, or a persistent browser profile.
  const cookies = new Map();
  const request = async (route, body, referer = address) => {
    const bytes = await fetchBuffer(new URL(route, base).href, {
      signal, timeoutMs: 12000, maxBytes: 2 * 1024 ** 2, followRedirect: false, label: 'SubHD 字幕',
      method: body ? 'POST' : 'GET', body: body ? JSON.stringify(body) : undefined,
      headers: { ...headers, Referer: referer, ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(cookies.size ? { Cookie: [...cookies].map(([key, value]) => `${key}=${value}`).join('; ') } : {}) },
      onResponse: response => {
        for (const entry of response.headers.getSetCookie()) {
          const pair = entry.split(';')[0], index = pair.indexOf('=');
          if (index > 0 && pair.length < 8192 && cookies.size < 30) cookies.set(pair.slice(0, index), pair.slice(index + 1));
        }
      },
    });
    if (!body) return bytes.toString('utf8');
    let data;
    try { data = JSON.parse(bytes.toString('utf8')); }
    catch { throw new AppError('SUBTITLE_PROVIDER', 'SubHD 暂未返回下载信息，可能需要验证，请稍后重试'); }
    if (data?.success !== true) throw new AppError('SUBTITLE_PROVIDER', text(data?.msg || 'SubHD 下载准备失败，请稍后重试').slice(0, 200));
    return data;
  };
  await request(base.pathname);
  const prepared = await request('/api/sub/prepare-download', { sid });
  if (typeof prepared.url !== 'string' || !/^\/down\/[a-z0-9]+$/i.test(prepared.url))
    throw new AppError('SUBTITLE_PROVIDER', 'SubHD 返回了无效的下载页面');
  await request(prepared.url);
  const result = await request('/api/sub/down', { sid }, new URL(prepared.url, base).href);
  if (result.pass !== true || typeof result.url !== 'string')
    throw new AppError('SUBTITLE_PROVIDER', text(result.msg || 'SubHD 当前请求需要验证，请稍后重试').slice(0, 200));
  let url;
  try { url = new URL(result.url, base); } catch { throw new AppError('SUBTITLE_URL', 'SubHD 下载地址无效'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password)
    throw new AppError('SUBTITLE_URL', 'SubHD 下载地址无效');
  let name;
  try { name = decodeURIComponent(url.pathname.split('/').at(-1)); } catch { name = sid + '.zip'; }
  return [{ url: url.href, name: name || sid + '.zip', format: name?.split('.').at(-1) || 'zip' }];
}
