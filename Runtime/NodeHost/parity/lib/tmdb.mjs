import path from 'node:path';
import { createHash } from 'node:crypto';
import { JsonStore } from './files.mjs';
import { approximateBytes } from './memory-budget.mjs';
import { AppError, requireText } from './errors.mjs';
import { providerJson } from './provider-http.mjs';
import { tmdbProxy } from './proxy-settings.mjs';
import { pickTmdbMatch, titleKey, tmdbEpisodePlan, tmdbQuery } from './tmdb-matching.mjs';

const list = value => Array.isArray(value) ? value : [];
const text = (value, limit = 12000) => typeof value === 'string' ? value.trim().slice(0, limit) : '';

const cacheMaxBytes = 16 * 1024 ** 2;
function trimCache(data, maxBytes = cacheMaxBytes) {
  let count = 0, bytes = 32, changed = false;
  for (const key of Object.keys(data).sort((a, b) => (Number(data[b]?.at) || 0) - (Number(data[a]?.at) || 0))) {
    const cost = key.length * 2 + 16 + approximateBytes(data[key], maxBytes - bytes);
    if (!data[key]?.value || count >= 128 || bytes + cost > maxBytes) { delete data[key]; changed = true; }
    else { count++; bytes += cost; }
  }
  return changed;
}

export const homeCategories = {
  trending: ['/trending/movie/week', 'movie', {}],
  latest: ['/movie/now_playing', 'movie', {}],
  rated: ['/movie/top_rated', 'movie', {}],
  chinese: ['/discover/tv', 'tv', { with_origin_country: 'CN' }],
  hongkong: ['/discover/tv', 'tv', { with_origin_country: 'HK|TW' }],
  asian: ['/discover/tv', 'tv', { with_origin_country: 'JP|KR', without_genres: '16' }],
  western: ['/discover/tv', 'tv', { with_origin_country: 'US|GB' }],
  animation: ['/discover/tv', 'tv', { with_genres: '16' }],
  documentary: ['/discover/movie', 'movie', { with_genres: '99' }],
  variety: ['/discover/tv', 'tv', { with_genres: '10764|10767' }],
};

const categoryFilters = {
  trending: {},
  latest: { 'vote_count.gte': 20 },
  rated: { 'vote_count.gte': 200, 'vote_average.gte': 7.5 },
  chinese: { with_original_language: 'zh', with_origin_country: 'CN', with_type: 4, without_genres: '10764,10766,10767' },
  hongkong: { with_origin_country: 'HK|TW', without_genres: '16,99,10764,10766,10767' },
  asian: { with_origin_country: 'JP|KR', without_genres: '16,99,10764,10766,10767' },
  western: { with_original_language: 'en', with_origin_country: 'US|GB', without_genres: '16,10764,10766,10767' },
  animation: { with_genres: '16' },
  documentary: { with_genres: '99' },
  variety: { with_genres: '10764' },
};
const regions = {
  zh: { with_original_language: 'zh' }, en: { with_original_language: 'en' },
  ko: { with_original_language: 'ko' }, ja: { with_original_language: 'ja' },
  CN: { with_original_language: 'zh', with_origin_country: 'CN' },
  HK: { with_origin_country: 'HK' }, TW: { with_origin_country: 'TW' },
  'HK|TW': { with_origin_country: 'HK|TW' }, US: { with_origin_country: 'US' }, GB: { with_origin_country: 'GB' },
};
function discoverFilters(category, filters, mediaType) {
  const params = { ...categoryFilters[category], ...(regions[filters.region] || {}) };
  if (filters.genre) params.with_genres = [params.with_genres, filters.genre].filter(Boolean).join(',');
  if (filters.year) params[mediaType === 'tv' ? 'first_air_date_year' : 'primary_release_year'] = filters.year;
  const sort = filters.sort || (category === 'latest' ? 'latest' : category === 'rated' ? 'rating' : 'popular');
  params.sort_by = sort === 'rating' ? 'vote_average.desc'
    : sort === 'latest' ? (mediaType === 'tv' ? 'first_air_date.desc' : 'primary_release_date.desc') : 'popularity.desc';
  if (sort === 'rating') params['vote_count.gte'] = Math.max(Number(params['vote_count.gte']) || 0, 80);
  if (sort === 'latest') {
    params[mediaType === 'tv' ? 'first_air_date.lte' : 'primary_release_date.lte'] = new Date().toISOString().slice(0, 10);
    if (mediaType === 'tv') params.include_null_first_air_dates = false;
  }
  return params;
}

function validateDiscoverFilters(filters) {
  if (!filters || typeof filters !== 'object' || Array.isArray(filters)
    || Object.keys(filters).some(key => !['mediaType', 'genre', 'region', 'year', 'sort'].includes(key))
    || (filters.mediaType !== undefined && !['movie', 'tv', 'both'].includes(filters.mediaType))
    || (filters.genre !== undefined && (typeof filters.genre !== 'string' || !/^(?:\d{1,5})?$/.test(filters.genre)))
    || (filters.year !== undefined && (typeof filters.year !== 'string' || !/^(?:19\d\d|20\d\d)?$/.test(filters.year)))
    || (filters.region !== undefined && filters.region !== '' && !Object.hasOwn(regions, filters.region))
    || (filters.sort !== undefined && !['popular', 'latest', 'rating'].includes(filters.sort)))
    throw new AppError('INVALID_ARGUMENT', '影视筛选条件无效');
}

export function tmdbImage(value, size = 'w500') {
  return typeof value === 'string' && /^\/(?:[\w-]+\/)*[\w-]+\.(?:jpg|jpeg|png|webp|svg)$/i.test(value)
    ? `https://image.tmdb.org/t/p/${size}${value}` : '';
}

function people(values, role) {
  const seen = new Set();
  return values.filter(person => {
    const key = Number.isSafeInteger(person?.id) && person.id > 0 ? person.id : null;
    if (!key || !text(person?.name) || seen.has(key)) return false;
    seen.add(key); return true;
  }).slice(0, role === '导演' ? 30 : 60).map(person => ({
    id: Number.isSafeInteger(person.id) ? person.id : 0,
    name: text(person.name, 300), profile: tmdbImage(person.profile_path, 'w185'),
    role: role || text(person.character || person.roles?.[0]?.character, 500) || '演员',
  }));
}

export function tmdbArtwork(raw, language = 'zh-CN') {
  const locale = language.toLowerCase().split('-')[0];
  const backdrops = list(raw.images?.backdrops).filter(image => tmdbImage(image?.file_path) && (!image.width || !image.height || image.width > image.height));
  const logos = list(raw.images?.logos).filter(image => tmdbImage(image?.file_path));
  const captioned = language => backdrops.find(image => image.iso_639_1 === language);
  const logoFor = language => logos.find(image => image.iso_639_1 === language);
  const original = backdrops.find(image => image.file_path === raw.backdrop_path);
  const neutral = backdrops.find(image => !image.iso_639_1)?.file_path
    || (!original?.iso_639_1 && raw.backdrop_path) || '';
  // The detail page composes its own title over the background. Keep textless
  // artwork and the localized logo separate so a captioned backdrop cannot
  // duplicate the foreground title or suppress an available transparent logo.
  const backdrop = neutral || captioned(locale)?.file_path || captioned('en')?.file_path
    || raw.backdrop_path || backdrops[0]?.file_path;
  const logo = logoFor(locale) || logoFor('en') || logos.find(image => !image.iso_639_1) || logos[0];
  return {
    backdrop: tmdbImage(backdrop, 'w1280'),
    backdrops: [...new Set([backdrop, ...backdrops.map(image => image.file_path)]
      .map(value => tmdbImage(value, 'w1280')).filter(Boolean))].slice(0, 8),
    backdropHasTitle: !!backdrops.find(image => image.file_path === backdrop)?.iso_639_1,
    logo: tmdbImage(logo?.file_path, 'w500'),
  };
}

function works(values, fallbackType) {
  const result = new Map();
  for (const item of values) {
    const mediaType = item?.media_type || fallbackType;
    if (!Number.isSafeInteger(item?.id) || item.id <= 0 || !['movie', 'tv'].includes(mediaType) || item.adult === true) continue;
    const value = normalizeTmdb({ ...item, media_type: mediaType });
    if (!value.title) continue;
    const key = `${mediaType}:${item.id}`;
    const role = item.job === 'Director' ? '导演' : item.character ? `饰 ${text(item.character, 150)}` : '';
    if (result.has(key)) {
      const previous = result.get(key);
      previous.role = [...new Set([...previous.role.split(' · '), role].filter(Boolean))].join(' · ');
      previous.poster ||= value.poster;
    } else result.set(key, { ...value, role });
  }
  return [...result.values()];
}

function credits(raw) {
  const cast = [...list(raw.credits?.cast), ...list(raw.aggregate_credits?.cast)];
  const crew = [...list(raw.credits?.crew), ...list(raw.aggregate_credits?.crew), ...list(raw.episodes).flatMap(episode => list(episode.crew))];
  return {
    cast: people(cast),
    directors: people(crew.filter(person => person?.job === 'Director' || list(person?.jobs).some(job => job.job === 'Director')), '导演'),
  };
}

export class TmdbService {
  constructor(directory, settings) {
    this.settings = settings;
    this.cacheBudget = cacheMaxBytes;
    this.lowMemory = false;
    this.cache = new JsonStore(path.join(directory, 'tmdb-cache.json'), {}, { normalize: trimCache });
    this.blocked = new Map();
  }
  async setMemoryPressure(low) {
    if (this.lowMemory === low) return;
    this.lowMemory = low;
    this.cacheBudget = low ? 4 * 1024 ** 2 : cacheMaxBytes;
    if (low) await this.cache.discardMemory();
  }
  async images(value) {
    const config = (await this.settings.private()).tmdb;
    const base = config.imageBase || 'https://image.tmdb.org/t/p';
    const rewrite = (item, thumbnail = false) => typeof item === 'string'
      ? item.replace(/^https:\/\/image\.tmdb\.org\/t\/p\/(w\d+|h\d+|original)\//,
        (_match, size) => `${base.replace(/\/+$/, '')}/${config.ultraHD && !thumbnail ? 'original' : size}/`)
      : Array.isArray(item) ? item.map(child => rewrite(child, thumbnail))
      : item && typeof item === 'object' ? Object.fromEntries(Object.entries(item).map(([key, child]) =>
        [key, rewrite(child, thumbnail || key === 'posterThumbnail' || key === 'backdropThumbnail')])) : item;
    return rewrite(value);
  }
  async discover({ category = 'trending', page = 1, filters, refresh = false } = {}, signal) {
    if (!Object.hasOwn(homeCategories, category) || !Number.isSafeInteger(page) || page < 1 || page > 500)
      throw new AppError('INVALID_ARGUMENT', '影视分类或页码无效');
    const [route, mediaType, base] = homeCategories[category];
    let raw, items, stale = false;
    const ttl = 15 * 60000;
    // Cached cards can paint immediately; the caller refreshes stale data while
    // retaining those cards. Detail/search requests keep their existing policy.
    const policy = { refresh, ttl, allowStale: true, rollingDate: true,
      onCache: entry => { stale ||= Date.now() - entry.at >= ttl; } };
    if (filters === undefined) {
      raw = await this.request(route, { ...base, page, include_adult: false, ...(route.startsWith('/discover/') ? { sort_by: 'popularity.desc' } : {}) }, signal, policy);
      items = works(list(raw.results), mediaType);
    } else {
      validateDiscoverFilters(filters);
      const mixed = ['latest', 'rated', 'documentary'].includes(category);
      if (!mixed && filters.mediaType && filters.mediaType !== mediaType)
        throw new AppError('INVALID_ARGUMENT', '当前分类不支持此作品类型');
      const selected = filters.mediaType || (mixed ? 'both' : mediaType);
      const types = selected === 'both' ? ['movie', 'tv'] : [selected];
      const responses = await Promise.all(types.map(async type => ({ type,
        value: await this.request(`/discover/${type}`, { ...discoverFilters(category, filters, type), page, include_adult: false }, signal, policy) })));
      const combined = responses.flatMap(({ type, value }) => list(value.results).map(item => ({ ...item, media_type: type })));
      const sort = filters.sort || (category === 'latest' ? 'latest' : category === 'rated' ? 'rating' : 'popular');
      combined.sort((a, b) => sort === 'latest'
        ? text(b.release_date || b.first_air_date).localeCompare(text(a.release_date || a.first_air_date))
        : (Number(sort === 'rating' ? b.vote_average : b.popularity) || 0) - (Number(sort === 'rating' ? a.vote_average : a.popularity) || 0));
      raw = { total_pages: Math.max(1, ...responses.map(({ value }) => Number(value.total_pages) || 1)) };
      items = works(combined, mediaType);
    }
    return this.images({ category, page, pageCount: Math.max(1, Math.min(500, Number(raw.total_pages) || 1)),
      // A rail's small cards do not need a decoded 4K original each. Preserve
      // full-quality artwork for hero/detail, with bounded retina thumbnails.
      items: items.slice(0, 40).map(item => ({ ...item, backdrop: item.backdrop.replace('/w1280/', '/w780/'),
        posterThumbnail: item.poster, backdropThumbnail: item.backdrop.replace('/w1280/', '/w780/') })),
      ...(stale ? { stale: true } : {}) });
  }
  async request(route, params = {}, signal, { refresh = false, ttl = 6 * 3600000, allowStale = false, rollingDate = false, onCache } = {}) {
    const config = (await this.settings.private()).tmdb;
    if (!config.enabled) throw new AppError('TMDB_DISABLED', '请先在设置中启用 TMDB');
    if (!config.token && !config.apiKey) throw new AppError('TMDB_CREDENTIALS', '请填写自己的 TMDB Read Access Token 或 API Key');
    const scope = createHash('sha256').update(config.apiBase + config.language + config.token + config.apiKey).digest('hex');
    const proxy = tmdbProxy(config);
    // A direct-route 403 must not block retrying through a newly configured
    // proxy. Keep metadata cache identity independent of network settings.
    const requestScope = createHash('sha256').update(scope + JSON.stringify(proxy || null)).digest('hex');
    const cacheKey = values => createHash('sha256').update(scope + route + JSON.stringify(values)).digest('hex');
    const dateKeys = rollingDate ? Object.keys(params).filter(name => ['primary_release_date.lte', 'first_air_date.lte'].includes(name)) : [];
    const identity = { ...params };
    for (const name of dateKeys) identity[name] = 'today';
    const key = cacheKey(identity);
    let cache = await this.cache.readKey(key);
    // Upgrade existing daily hashes without scanning/cloning the raw cache.
    // The next successful refresh writes the stable key, within the same cap.
    if (!cache && dateKeys.length) for (let days = 0; days < 31 && !cache; days++) {
      const legacy = { ...params }, date = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
      for (const name of dateKeys) legacy[name] = date;
      cache = await this.cache.readKey(cacheKey(legacy));
    }
    if (!refresh && cache && (allowStale || Date.now() - cache.at < ttl)) { onCache?.(cache); return cache.value; }
    if ((this.blocked.get(requestScope) || 0) > Date.now()) throw new AppError('TMDB_AUTH', 'TMDB 认证失败后暂缓请求，请检查凭据');
    const url = new URL(config.apiBase + route);
    url.searchParams.set('language', config.language);
    if (!config.token) url.searchParams.set('api_key', config.apiKey);
    for (const [name, value] of Object.entries(params)) url.searchParams.set(name, String(value));
    try {
      const value = await providerJson(url, { label: 'TMDB', signal, timeoutMs: 12000, proxy,
        headers: config.token ? { Authorization: `Bearer ${config.token}` } : {} });
      if (!value || typeof value !== 'object' || value.success === false) throw new AppError('TMDB_RESPONSE', 'TMDB 未返回有效资料');
      signal?.throwIfAborted();
      await this.cache.update((data) => {
        data[key] = { at: Date.now(), value: structuredClone(value) };
        trimCache(data, this.cacheBudget);
      });
      return value;
    } catch (error) {
      if ([401, 403].includes(error.httpStatus)) this.blocked.set(requestScope, Date.now() + 300000);
      if (cache && !signal?.aborted && ![401, 403].includes(error.httpStatus)) { onCache?.(cache); return cache.value; }
      throw error;
    }
  }
  async search({ query }, signal) {
    const value = await this.request('/search/multi', { query: requireText(query, '片名', 200), include_adult: false }, signal);
    return this.images({ items: list(value.results).filter(item => Number.isSafeInteger(item?.id) && item.id > 0 && ['movie', 'tv'].includes(item.media_type))
      .slice(0, 30).map(normalizeTmdb) });
  }
  async resolve(params, signal) {
    const query = tmdbQuery(params.title);
    if (!query || /^https?:\/\//i.test(query)) return { query, metadata: null, candidates: [] };
    const { items } = await this.search({ query }, signal);
    const match = pickTmdbMatch(items, params);
    return { query, candidates: items, metadata: match ? await this.detail(match, signal) : null };
  }
  async detail({ tmdbId, mediaType, refresh = false }, signal) {
    validateIdentity(tmdbId, mediaType);
    const { language } = (await this.settings.private()).tmdb;
    const raw = await this.request(`/${mediaType}/${tmdbId}`, {
      append_to_response: mediaType === 'tv' ? 'credits,aggregate_credits,images,recommendations,external_ids' : 'credits,images,recommendations,external_ids',
      include_image_language: [...new Set([language.split('-')[0].toLowerCase(), 'en', 'null'])].join(','),
    }, signal, { refresh });
    if (raw.id !== tmdbId) throw new AppError('TMDB_RESPONSE', 'TMDB 未返回对应作品资料');
    const credit = credits(raw);
    const networkIds = new Set();
    const networks = (mediaType === 'tv' ? list(raw.networks) : []).filter(network => {
      if (!Number.isSafeInteger(network?.id) || network.id <= 0 || !text(network.name) || networkIds.has(network.id)) return false;
      networkIds.add(network.id); return true;
    }).map(network => ({ id: network.id, name: text(network.name, 300), logo: tmdbImage(network.logo_path, 'w92') }));
    return this.images({ ...normalizeTmdb({ ...raw, media_type: mediaType }), ...tmdbArtwork(raw, language),
      imdbId: /^tt\d+$/.test(raw.external_ids?.imdb_id || raw.imdb_id || '') ? raw.external_ids?.imdb_id || raw.imdb_id : null,
      runtime: [raw.runtime, ...list(raw.episode_run_time)].find(value => Number.isFinite(value) && value > 0 && value < 10000) || null,
      genres: [...new Set(list(raw.genres).map(genre => text(genre?.name, 100)).filter(Boolean))].slice(0, 10),
      countries: [...new Set([...list(raw.origin_country), ...list(raw.production_countries).map(country => country?.iso_3166_1)]
        .filter(country => typeof country === 'string' && /^[A-Z]{2}$/.test(country)))].slice(0, 10),
      originalLanguage: text(raw.original_language, 10),
      episodeCount: Number.isSafeInteger(raw.number_of_episodes) && raw.number_of_episodes > 0 ? raw.number_of_episodes : null,
      nextEpisode: mediaType === 'tv' ? nextAiring(raw.next_episode_to_air) : null,
      status: mediaType === 'tv' && typeof raw.status === 'string' ? raw.status.slice(0, 64) : '',
      lastEpisode: mediaType === 'tv' ? nextAiring(raw.last_episode_to_air) : null,
      networks,
      recommendations: works(list(raw.recommendations?.results), mediaType)
        .filter(item => item.tmdbId !== tmdbId || item.mediaType !== mediaType).slice(0, 20),
      seasons: list(raw.seasons).filter(season => Number.isSafeInteger(season?.season_number) && season.season_number >= 0 && season.season_number <= 1000)
        .map(season => ({ number: season.season_number, name: text(season.name, 300),
          episodeCount: Number.isSafeInteger(season.episode_count) && season.episode_count > 0 ? season.episode_count : 0 }))
        .sort((a, b) => a.number - b.number),
      ...credit, actors: credit.cast.slice(0, 12).map(person => person.name).join(' / ') });
  }
  async person({ personId }, signal) {
    if (!Number.isSafeInteger(personId) || personId <= 0) throw new AppError('INVALID_ARGUMENT', '人物身份无效');
    const raw = await this.request(`/person/${personId}`, { append_to_response: 'combined_credits' }, signal);
    if (raw.id !== personId) throw new AppError('TMDB_RESPONSE', 'TMDB 未返回对应人物资料');
    const credits = [...list(raw.combined_credits?.cast), ...list(raw.combined_credits?.crew)]
      .sort((a, b) => (Number(b.popularity) || 0) - (Number(a.popularity) || 0)
        || String(b.release_date || b.first_air_date || '').localeCompare(String(a.release_date || a.first_air_date || '')));
    return this.images({ id: personId, name: text(raw.name, 300), profile: tmdbImage(raw.profile_path, 'w185'), works: works(credits) });
  }
  async season({ tmdbId, season, refresh = false }, signal) {
    validateIdentity(tmdbId, 'tv');
    if (!Number.isSafeInteger(season) || season < 0 || season > 1000) throw new AppError('INVALID_ARGUMENT', '季度无效');
    const raw = await this.request(`/tv/${tmdbId}/season/${season}`, { append_to_response: 'credits' }, signal, { refresh });
    return this.images({ season, ...credits(raw), episodes: list(raw.episodes)
      .filter(item => Number.isSafeInteger(item?.episode_number) && item.episode_number > 0)
      .map(item => ({ season, number: item.episode_number, name: text(item.name, 500),
        overview: text(item.overview), date: text(item.air_date, 30), still: tmdbImage(item.still_path),
        runtime: Number.isFinite(item.runtime) && item.runtime > 0 ? item.runtime : null })) });
  }
  async episodes({ tmdbId, title, flag, names, mapping }, signal) {
    validateIdentity(tmdbId, 'tv');
    if (!Array.isArray(names) || names.length > 10000 || names.some(name => typeof name !== 'string' || name.length > 8192))
      throw new AppError('INVALID_ARGUMENT', '剧集列表无效');
    const metadata = await this.detail({ tmdbId, mediaType: 'tv' }, signal);
    const plan = tmdbEpisodePlan(names, { title, flag, seasons: metadata.seasons, mapping });
    const pending = [...new Set(plan.filter(Boolean).map(item => item.season))];
    const seasons = new Map();
    let unavailable = false;
    const deadline = AbortSignal.timeout(25000);
    const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
    await Promise.all(Array.from({ length: Math.min(3, pending.length) }, async () => {
      while (pending.length) {
        const season = pending.shift();
        if (combined.aborted) { unavailable = true; break; }
        try { seasons.set(season, await this.season({ tmdbId, season }, combined)); }
        catch { unavailable = true; }
      }
    }));
    signal?.throwIfAborted();
    const uniquePeople = key => [...new Map([...seasons.values()].flatMap(item => item[key]).map(person => [person.id || person.name, person])).values()];
    return {
      episodes: plan.map((item, index) => {
        if (!item) return null;
        const episodes = seasons.get(item.season)?.episodes || [];
        if (item.number !== null) return episodes.find(episode => episode.number === item.number) || null;
        const matches = episodes.filter(episode => titleKey(episode.name) && titleKey(episode.name) === titleKey(names[index]));
        return matches.length === 1 ? matches[0] : null;
      }),
      cast: uniquePeople('cast'), directors: uniquePeople('directors'), unavailable,
    };
  }
}
function nextAiring(episode) {
  const date = episode?.air_date;
  if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  const parsed = new Date(date + 'T00:00:00Z');
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date
    || !Number.isSafeInteger(episode.season_number) || episode.season_number < 0 || episode.season_number > 1000
    || !Number.isSafeInteger(episode.episode_number) || episode.episode_number <= 0) return null;
  return { date, season: episode.season_number, number: episode.episode_number };
}

export function validateIdentity(id, type) {
  if (!Number.isSafeInteger(id) || id <= 0 || !['movie', 'tv'].includes(type)) throw new AppError('INVALID_ARGUMENT', '作品身份无效');
}
export function normalizeTmdb(item) {
  return { tmdbId: item.id, mediaType: item.media_type, title: text(item.title || item.name, 500),
    rating: Number.isFinite(item.vote_average) ? Math.round(item.vote_average * 10) / 10 : null,
    originalTitle: text(item.original_title || item.original_name, 500), year: text(item.release_date || item.first_air_date, 4),
    overview: text(item.overview), poster: tmdbImage(item.poster_path), backdrop: tmdbImage(item.backdrop_path, 'w1280') };
}
