import { AppError } from './errors.mjs';

export function proxyUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw new AppError('PROXY_URL', '代理地址无效，请填写协议、主机和端口'); }
  if (!['http:', 'https:', 'socks5:'].includes(url.protocol) || !url.hostname || url.port === '0'
    || url.username || url.password || (url.pathname && url.pathname !== '/') || url.search || url.hash)
    throw new AppError('PROXY_URL', '代理地址仅支持 HTTP、HTTPS 或 SOCKS5，账号密码请单独填写');
  return `${url.protocol}//${url.host}`;
}

export function tmdbProxy(config) {
  if (!config.proxyEnabled) return undefined;
  if (!config.proxyUrl) throw new AppError('PROXY_URL', '启用代理后请填写代理地址');
  return { url: proxyUrl(config.proxyUrl), username: config.proxyUsername || '', password: config.proxyPassword || '' };
}

export function isTmdbImage(address, config) {
  try {
    const url = new URL(address);
    return ['https://image.tmdb.org/t/p', config.imageBase].filter(Boolean).some(base => {
      const target = new URL(base);
      return url.origin === target.origin && url.pathname.startsWith(target.pathname.replace(/\/+$/, '') + '/');
    });
  } catch { return false; }
}
