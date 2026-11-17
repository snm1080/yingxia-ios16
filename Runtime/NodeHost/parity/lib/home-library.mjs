import { createHash } from 'node:crypto';
import { AppError, requireText } from './errors.mjs';
import { providerJson } from './provider-http.mjs';
import { panSearchRequest } from './pan-search-options.mjs';

const string = value => typeof value === 'string' ? value.trim().slice(0, 2048) : '';

// Push providers parse the share URL itself. Appending human-readable password
// text corrupts either the final query value or the share ID in those parsers.
export function normalizePanShare(rawUrl, suppliedPassword = '', diskType = '') {
  const url = string(rawUrl);
  let input = url.replace(/&(?:amp|#38|#x26);/gi, '&');
  // Some PanSou plugins put the provider's complete clipboard text in `url`.
  // The util parser also accepts unlabelled clipboard links and punctuation
  // immediately before the code. Do not mistake a magnet's tracker for a share.
  const copied = !/^(?:magnet:|ed2k:)/i.test(input)
    && input.match(/https?:\/\/[^\s<>"'，。；;（）「」【】]+/i);
  const copiedPassword = copied && input.slice(copied.index + copied[0].length).split(/https?:\/\//i)[0]
    .match(/(?:提取码|访问码|密码|口令|code|pwd)\s*[:：= ]\s*([^\s，。；;（）「」【】]+)/i)?.[1];
  if (copied) input = copied[0].replace(/[!！?？)\]】」』#]+$/, '');
  const suffix = input.match(/\s+(?:提取码|访问码|密码)\s*[:：]\s*(\S+)\s*$/);
  if (suffix) input = input.slice(0, suffix.index).trim();
  let password = string(suppliedPassword || copiedPassword || suffix?.[1]).slice(0, 100);
  const legacyCode = diskType === '123' && input.match(/\?\?([^?&#\s]+)$/);
  if (legacyCode) {
    password ||= legacyCode[1];
    input = input.slice(0, legacyCode.index);
  }
  const allowed = value => /^(https?:\/\/|magnet:\?|ed2k:\/\/)/i.test(value);
  if (!allowed(input)) return null;
  if (/^https?:/i.test(input)) {
    let parsed;
    try { parsed = new URL(input); } catch { return null; }
    if (parsed.username || parsed.password) return null;
    if (parsed.hostname === 'toapp.mypikpak.com' && parsed.pathname === '/toapp') {
      const nested = parsed.searchParams.get('__add_url');
      if (!nested || !allowed(nested)) return null;
      const normalized = normalizePanShare(nested, password, diskType);
      return normalized ? { ...normalized, url } : null;
    }
    const passwordKeys = ['pwd', 'password', 'passcode', 'pass_code', 'sharepwd', 'share_pwd', 'accesscode', '提取码', ...(diskType === 'guangya' ? ['code'] : [])];
    const matchingKeys = [...parsed.searchParams.keys()].filter(key => passwordKeys.includes(key.toLowerCase()));
    const labelledKey = [...parsed.searchParams.keys()].find(key => /^(?:pwd|password|passcode|sharepwd|提取码)[:：][^\s]+$/i.test(key));
    const fragment = new URLSearchParams(parsed.hash.slice(1));
    password ||= string(matchingKeys.map(key => parsed.searchParams.get(key)).find(Boolean)
      || labelledKey?.split(/[:：]/).slice(1).join(':') || fragment.get('pass_code') || (diskType === 'mobile' && parsed.hash.match(/[?&](?:pwd|password)=([^&#]+)/)?.[1])
      || (diskType === 'guangya' && (fragment.get('code') || parsed.hash.match(/^#([a-zA-Z0-9]{4,8})$/)?.[1]))).slice(0, 100);
    const parameter = { aliyun: 'pwd', tianyi: 'accessCode', mobile: 'pwd', quark: 'pwd', baidu: 'pwd', '123': 'pwd', uc: 'pwd', xunlei: 'pwd', '115': 'password', pikpak: 'pass_code', guangya: 'code' }[diskType];
    // Keep every extraction code in the actual click/push input. The mobile
    // host adapts known legacy parsers that used to discard these queries.
    if (password && diskType === 'mobile' && parsed.pathname === '/m/i' && !parsed.search.slice(1).split('&')[0].includes('=')) {
      // This legacy URL stores the ID as a bare query key. URLSearchParams.set
      // would serialize it as id= and change the value read by the provider.
      parsed.search = parsed.search.split('&')[0] + '&pwd=' + encodeURIComponent(password);
    } else if (password && diskType === 'mobile' && /^#\/w\/i\//.test(parsed.hash)) {
      // Keep the route directly after /shareweb/#; the subscribed detector does
      // not recognize a query inserted before this provider's fragment route.
      const route = parsed.hash.replace(/[?&](?:pwd|password)=[^&#]*/g, '');
      parsed.hash = route + (route.includes('?') ? '&' : '?') + 'pwd=' + encodeURIComponent(password);
    } else if (password && parameter) {
      for (const key of matchingKeys) parsed.searchParams.delete(key);
      if (labelledKey) parsed.searchParams.delete(labelledKey);
      const rest = parsed.searchParams.toString();
      if (diskType === '115') parsed.search = `password=${encodeURIComponent(password)}${rest ? '&' + rest : ''}`;
      else parsed.searchParams.set(parameter, password);
      if (diskType === 'pikpak' && fragment.has('pass_code')) { fragment.delete('pass_code'); parsed.hash = fragment.toString(); }
      if (diskType === 'guangya' && (fragment.has('code') || /^#[a-zA-Z0-9]{4,8}$/.test(parsed.hash))) parsed.hash = '';
    }
    input = parsed.toString();
  }
  return { url, input, password };
}

// PanSou's merged protocol is the same one used by the reference library.
// Keep real share links and extraction codes; metadata IDs never become playback inputs.
export class HomeLibrary {
  constructor(tmdb, settings) { this.tmdb = tmdb; this.settings = settings; }
  async search({ query, year = '' }, signal) {
    query = requireText(query, '片名', 200);
    const config = (await this.settings.private()).tmdb;
    const request = panSearchRequest(query, config);
    const endpoint = new URL(config.panApiBase);
    const pathname = endpoint.pathname.replace(/\/+$/, '');
    endpoint.pathname = pathname.endsWith('/api/search') ? pathname : `${pathname}/api/search`;
    const body = await providerJson(endpoint, {
      label: '盘搜', signal, timeoutMs: 30000, maxBytes: 8 * 1024 ** 2,
      json: request,
      headers: config.panToken ? { Authorization: `Bearer ${config.panToken}` } : {},
    });
    const data = body?.data || body;
    const hasMerged = data?.merged_by_type && typeof data.merged_by_type === 'object' && !Array.isArray(data.merged_by_type);
    const hasResults = Array.isArray(data?.results);
    const failed = body?.success === false || (body?.code !== undefined && ![0, 200, '0', '200'].includes(body.code));
    if (failed || !data || !hasMerged && !hasResults)
      throw new AppError('PAN_RESPONSE', failed && string(body.message || body.msg)
        ? `盘搜服务返回错误：${string(body.message || body.msg).slice(0, 300)}`
        : '盘搜未返回有效资源，请检查服务地址或访问令牌');
    const groups = hasMerged ? Object.entries(data.merged_by_type) : [];
    // In merge mode the service has already filtered individual links for
    // relevance. The explicitly requested all/results modes retain raw links
    // too; a merged section must not make unique raw links disappear.
    const useResults = hasResults && (!hasMerged || request.res !== 'merge');
    if (useResults) for (const result of data.results) for (const link of Array.isArray(result?.links) ? result.links : []) {
      groups.push([link?.type || link?.disk_type, [{ ...link, note: link?.work_title || link?.note || result.title,
        source: link?.source || result.channel || result.source, datetime: link?.datetime || result.datetime }]]);
    }
    const counts = { received: 0, parsed: 0, unique: 0, duplicates: 0, rejected: 0,
      ...(Number.isSafeInteger(Number(data.total)) && Number(data.total) >= 0 && data.total !== null && data.total !== undefined
        ? { upstream: Number(data.total), upstreamUnit: useResults ? 'records' : 'links' } : {}) };
    const seen = new Map(), items = [];
    for (const [diskType, links] of groups) {
      if (!Array.isArray(links)) continue;
      for (const link of links) {
        counts.received++;
        if (typeof diskType !== 'string' || ['__proto__', 'constructor', 'prototype'].includes(diskType)) { counts.rejected++; continue; }
        const normalized = normalizePanShare(link?.url || link?.link || link?.href,
          link?.password || link?.pwd || link?.passcode || link?.code, diskType);
        if (!normalized) { counts.rejected++; continue; }
        counts.parsed++;
        const { url, input, password } = normalized;
        const title = string(link.note || link.name || link.title || link.work_title) || query;
        const previous = seen.get(url);
        if (previous) {
          counts.duplicates++;
          if (!previous.password && password) {
            previous.password = password;
            previous.input = input;
          }
          previous.source ||= string(link.source || link.channel);
          previous.datetime ||= string(link.datetime);
          continue;
        }
        const item = { id: createHash('sha256').update(url).digest('hex').slice(0, 20), title, url, input,
          diskType, password, source: string(link.source || link.channel), datetime: string(link.datetime) };
        seen.set(url, item);
        items.push(item);
      }
    }
    items.sort((a, b) => Number(b.title.includes(query)) - Number(a.title.includes(query))
      || (year ? Number(b.title.includes(year)) - Number(a.title.includes(year)) : 0));
    counts.unique = items.length;
    const incomplete = counts.upstream > (useResults ? data.results.length : counts.received);
    return { query, items, counts, partial: !!(incomplete || data.partial || data.errors?.length || body?.errors?.length) };
  }
}
