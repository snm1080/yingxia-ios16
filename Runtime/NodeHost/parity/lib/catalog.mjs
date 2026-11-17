const disabled = (value) => value === false || value === 0 || value === '0' || value === 'false';
export const siteIntegrationEnabled = value => [true, 1, '1', 'true'].includes(value);
export function siteCapabilities(site) {
  const indexs = Number(site.indexs) === 1;
  return {
    key: String(site.key),
    name: String(site.name || site.key),
    type: site.type,
    indexs,
    siteSettings: siteIntegrationEnabled(site.siteSettings),
    panCheck: siteIntegrationEnabled(site.panCheck),
    searchable: !indexs && !disabled(site.searchable) && !disabled(site.supportSearch),
  };
}

export function cardNavigation(item, site = {}) {
  if (Number(site.indexs) === 1 || site.indexs === true) return { kind: 'search' };
  const tag = String(item.vod_tag || item.tag || item.kind || '').toLowerCase();
  const cate =
    item.cate && typeof item.cate === 'object' && !Array.isArray(item.cate) ? item.cate : null;
  const folder =
    tag === 'folder' || item.extend?.type === 'folder' || item.is_dir === true || cate !== null;
  if (folder)
    return {
      kind: 'folder',
      categoryId: String(
        cate
          ? (cate.id ?? item.vod_id ?? item.id ?? item.type_id ?? '')
          : (item.type_id ?? item.vod_id ?? item.id ?? ''),
      ),
      categoryFilters: cate?.filters || cate?.extend || item.categoryFilters || {},
    };
  return { kind: ['video', 'playlist', 'subtitle', 'file'].includes(tag) ? tag : 'detail' };
}

export function filterDefaults(filters = []) {
  return Object.fromEntries(
    (Array.isArray(filters) ? filters : [])
      .filter((filter) => filter?.key && filter.init !== undefined)
      .map((filter) => [filter.key, String(filter.init)]),
  );
}

// Sources use [] and {} interchangeably for empty categories. Normalize the
// boundary once so consumers never have to call array methods on source data.
export function normalizeFilters(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return {};
  return Object.fromEntries(Object.entries(input).map(([category, raw]) => {
    const rows = Array.isArray(raw) ? raw : raw && typeof raw === 'object'
      ? raw.key ? [raw] : Object.entries(raw).map(([key, value]) =>
          Array.isArray(value) ? { key, value } : { ...value, key: value?.key ?? key })
      : [];
    const seen = new Set();
    const filters = rows.filter(row => row && typeof row === 'object' && row.key != null && Array.isArray(row.value))
      .map(row => {
        const choices = new Set();
        return { ...row, key: String(row.key), name: String(row.name ?? ''),
        ...(row.init != null ? { init: String(row.init) } : {}),
        value: row.value.filter(option => option && typeof option === 'object' && option.v != null)
          .map(option => ({ n: String(option.n ?? option.v), v: String(option.v) }))
          .filter(option => !choices.has(option.v) && choices.add(option.v)),
        };
      })
      .filter(row => row.key && row.value.length && !seen.has(row.key) && seen.add(row.key));
    return [category, filters];
  }));
}

export function normalizeClasses(classes) {
  return (Array.isArray(classes) ? classes : [])
    .filter((item) => item && item.type_id !== undefined)
    .map((item) => ({
      ...item,
      type_id: String(item.type_id),
      type_name: String(item.type_name || item.type_id).trim(),
    }));
}

export function categoryFilters(result, id) {
  const input = result?.filters ?? result?.filter;
  // Some spiders discover facets only after fetching a category page, using a
  // singular `filter` array. Keep their numeric/string keys exactly as returned.
  return normalizeFilters(Array.isArray(input) || input?.key != null ? { [String(id)]: input } : input);
}

export function posterAddress(input, baseUrl) {
  const value =
    typeof input === 'object' && input
      ? input.url || input.normal || input.large || input.medium
      : input;
  const text = String(value || '').trim();
  if (!text || text.startsWith('/poster/')) return text;
  try {
    const url = new URL(text.replace(/js2p:\/\/_WEB_/gi, baseUrl || ''), baseUrl);
    return ['http:', 'https:'].includes(url.protocol) ? url.toString() : '';
  } catch {
    return '';
  }
}

export function posterRequestHeaders(input) {
  const hostname = new URL(input).hostname.toLowerCase();
  const headers = {
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    Accept: 'image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.5',
  };
  if (
    ['douban.com', 'doubanio.com', 'doubanusercontent.com'].some(
      (domain) => hostname === domain || hostname.endsWith(`.${domain}`),
    )
  )
    headers.Referer = 'https://movie.douban.com/';
  if (['hdslb.com', 'bilibili.com', 'bilivideo.com'].some(domain => hostname === domain || hostname.endsWith(`.${domain}`)))
    headers.Referer = 'https://www.bilibili.com/';
  return headers;
}
