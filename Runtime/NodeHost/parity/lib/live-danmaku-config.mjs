// Keep live connection credentials out of the downloadable danmaku URL.
export function normalizeLiveDanmaku(value, baseUrl = '') {
  if (typeof value === 'string') value = { version: 1, platform: 'json', url: value };
  if (!value || typeof value !== 'object' || Array.isArray(value) || value.version !== 1
    || !['bilibili', 'douyu', 'douyin', 'huya', 'json'].includes(value.platform)) return undefined;
  let url;
  try {
    const base = baseUrl ? baseUrl.replace(/^http/i, 'ws') : undefined;
    url = new URL(String(value.url || ''), base);
    if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password || url.href.length > 32768) return undefined;
  } catch { return undefined; }
  const roomId = String(value.roomId ?? '').trim();
  if (value.platform !== 'json' && !/^[1-9]\d{0,31}$/.test(roomId)) return undefined;
  const headers = {};
  if (value.headers && typeof value.headers === 'object' && !Array.isArray(value.headers)) {
    for (const [key, entry] of Object.entries(value.headers).slice(0, 32)) {
      if (/^[!#$%&'*+.^_`|~\da-z-]+$/i.test(key) && typeof entry === 'string' && entry.length <= 16384
        && !/[\r\n\u0000]/.test(entry) && !/^(?:host|connection|upgrade|content-length|transfer-encoding|sec-websocket-.*)$/i.test(key)) headers[key] = entry;
    }
  }
  const result = { version: 1, platform: value.platform, url: url.href, roomId, headers };
  for (const key of ['uid', 'token', 'buvid', 'channelId', 'subChannelId', 'presenterUid', 'groupId']) {
    if (typeof value[key] === 'string' || typeof value[key] === 'number') {
      const entry = String(value[key]);
      if (entry.length <= 16384 && !/[\r\n\u0000]/.test(entry)) result[key] = entry;
    }
  }
  return result;
}
