import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { JsonStore } from './files.mjs';
import { AppError, requireText } from './errors.mjs';
import { validateIdentity } from './tmdb.mjs';
import { episodeNumbers, isEpisodeExtra } from './episode-numbers.mjs';
export { episodeNumbers } from './episode-numbers.mjs';

const hash = (parts) => createHash('sha256').update(JSON.stringify(parts)).digest('hex');
export const sourceItemKey = (item) => hash([item.sourceId || '', item.siteKey || '', item.vodId || item.id || item.direct || '']);
export const episodePreferenceKey = (request) => hash([request.sourceId || '', request.siteKey || '', request.vodId || '', request.flag || '', request.id || request.direct || '']);
const seriesKey = (request) => hash([request.sourceId || '', request.siteKey || '', request.vodId || request.direct || '', request.flag || '']);
const number = (value, max) => typeof value === 'number' && Number.isFinite(value) ? Math.max(0, Math.min(max, value)) : 0;
export function skipPreferences(preferences = {}) {
  const result = { ...preferences };
  const auto = preferences.autoOpening !== false && preferences.autoEnding !== false;
  result.autoOpening = auto; result.autoEnding = auto;
  for (const part of ['opening', 'ending']) {
    const field = `${part}Override`;
    if (!Object.hasOwn(result, field)) result[field] = preferences.skipMode === 'manual' && preferences[part] > 0 ? preferences[part] : null;
  }
  return result;
}
function effectivePreferences(line = {}, episode = {}) {
  const result = { ...line, ...episode };
  // Resource selections cannot be inherited by another episode, including
  // associations written by older callers using the series preference scope.
  if (!Object.hasOwn(episode, 'danmaku')) delete result.danmaku;
  if (line.skipSchema === 2) for (const field of ['openingOverride', 'endingOverride', 'autoOpening', 'autoEnding']) result[field] = line[field];
  return skipPreferences(result);
}
function previousDanmaku(write) {
  return write.previousWrite && write.previousWrite.state !== 'committed'
    ? previousDanmaku(write.previousWrite) : write.previous;
}
export function resolveMediaIdentity(request, binding) {
  if (!binding?.metadata || isEpisodeExtra(request.episodeName)) return null;
  const { tmdbId, mediaType } = binding.metadata;
  if (mediaType === 'movie') return { tmdbId, mediaType, season: null, episode: null, key: `tmdb:movie:${tmdbId}` };
  const explicit = episodeNumbers(request.episodeName), inferred = episodeNumbers(`${request.flag || ''} ${binding.source.title || ''}`);
  const mapping = binding.lines?.[request.flag || ''];
  // A lone first season is unambiguous. A partial season list beginning at a
  // later season is not enough evidence to assign unlabelled episodes to it.
  const seasons = binding.metadata.seasons?.filter(item => item.number > 0) || [];
  const singleSeason = seasons.length === 1 && seasons[0].number === 1 ? 1 : null;
  const season = mapping?.season ?? explicit.season ?? inferred.season ?? singleSeason;
  const episode = explicit.episode === null ? null : explicit.episode + (mapping?.offset || 0);
  if (!Number.isSafeInteger(season) || season < 0 || !Number.isSafeInteger(episode) || episode < 1) return null;
  const known = binding.metadata.seasons?.find((item) => item.number === season);
  if (!known || (known.episodeCount > 0 && episode > known.episodeCount)) return null;
  if (mapping?.season !== undefined && explicit.season !== null && mapping.season !== explicit.season) return null;
  return { tmdbId, mediaType, season, episode, key: `tmdb:tv:${tmdbId}:${season}:${episode}` };
}
export class MediaIdentityStore {
  constructor(directory) {
    this.store = new JsonStore(path.join(directory, 'media-library.json'), { schema: 1, bindings: {}, episodes: {}, series: {} });
    this.danmakuWrites = new Map();
  }
  async binding(source) { return (await this.store.read()).bindings[sourceItemKey(source)] || null; }
  async bind(source, metadata) {
    for (const key of ['sourceId', 'siteKey', 'vodId']) requireText(source[key], key, 8192);
    validateIdentity(metadata.tmdbId, metadata.mediaType);
    const item = { source: { sourceId: source.sourceId, siteKey: source.siteKey, vodId: source.vodId, title: String(source.title || '').slice(0, 500) },
      metadata, lines: {}, updatedAt: new Date().toISOString() };
    await this.store.update((data) => { data.bindings[sourceItemKey(source)] = item; });
    return item;
  }
  async unbind(source) { await this.store.update((data) => { delete data.bindings[sourceItemKey(source)]; }); return { ok: true }; }
  async mapLine(source, { flag, season, offset = 0 }) {
    await this.store.update((data) => {
      const binding = data.bindings[sourceItemKey(source)];
      if (!binding) throw new AppError('MEDIA_UNBOUND', '请先绑定作品');
      if (season === null) delete binding.lines[String(flag || '')];
      else {
        if (!binding.metadata.seasons?.some((item) => item.number === season) || !Number.isSafeInteger(offset) || Math.abs(offset) > 10000)
          throw new AppError('INVALID_ARGUMENT', '季度或集号偏移无效');
        binding.lines[String(flag || '').slice(0, 500)] = { season, offset };
      }
    });
    return this.binding(source);
  }
  async decorate(request) {
    const binding = await this.binding({ ...request, id: request.vodId });
    return { identity: resolveMediaIdentity(request, binding), metadata: binding?.metadata || null };
  }
  async preferences(request) {
    const data = await this.store.read();
    const episode = { ...data.episodes[episodePreferenceKey(request)] };
    const write = this.danmakuWrites.get(episode.danmaku?._selection);
    if (write && write.state !== 'committed') {
      const previous = previousDanmaku(write);
      if (previous === undefined) delete episode.danmaku;
      else episode.danmaku = previous;
    }
    const preferences = effectivePreferences(data.series[seriesKey(request)], episode);
    // The automatic switch belongs to the app; durations still belong to a
    // playlist. Apply it last so legacy episode/series values cannot undo it.
    if (typeof data.autoIntroSkip === 'boolean') {
      preferences.autoOpening = data.autoIntroSkip;
      preferences.autoEnding = data.autoIntroSkip;
    }
    if (preferences.danmaku?._selection) {
      const { _selection, ...resource } = preferences.danmaku;
      preferences.danmaku = resource;
    }
    return preferences;
  }
  async stageDanmaku(request, resource, guard) {
    const write = { id: randomUUID(), state: 'pending', previous: undefined, previousWrite: null };
    const check = () => {
      guard();
      if (write.state !== 'pending') throw new AppError('API_CANCELLED', '弹幕选择已改变，已取消旧关联');
    };
    const rollback = async () => {
      write.state = 'cancelled';
      await this.store.update((data) => {
        const episode = data.episodes[episodePreferenceKey(request)];
        if (episode?.danmaku?._selection !== write.id) return;
        const previous = previousDanmaku(write);
        if (previous === undefined) delete episode.danmaku;
        else episode.danmaku = previous;
      });
      this.danmakuWrites.delete(write.id);
    };
    try {
      await this.remember(request, { danmaku: resource }, 'episode', check, write);
    } catch (error) {
      await rollback();
      throw error;
    }
    return {
      check,
      commit: () => { check(); write.state = 'committed'; this.danmakuWrites.delete(write.id); },
      rollback,
    };
  }
  async remember(request, patch, scope = 'episode', guard = () => {}, danmakuWrite) {
    const clean = {};
    if (patch.skipSchema === 2) clean.skipSchema = 2;
    for (const key of ['subtitle', 'danmaku']) if (patch[key] !== undefined) {
      if (patch[key] !== null && (typeof patch[key] !== 'object' || typeof patch[key].url !== 'string' || patch[key].url.length > 32768))
        throw new AppError('INVALID_ARGUMENT', '关联资源无效');
      clean[key] = patch[key] === null ? null : { url: patch[key].url, name: String(patch[key].name || '').slice(0, 300) };
      if (key === 'danmaku' && clean[key]) {
        if (/^[a-f\d]{64}$/.test(patch[key].cacheId || '')) clean[key].cacheId = patch[key].cacheId;
        if (typeof patch[key].sourceId === 'string') clean[key].sourceId = patch[key].sourceId.slice(0, 500);
        if (typeof patch[key].standalone === 'boolean') clean[key].standalone = patch[key].standalone;
      }
    }
    for (const key of ['opening', 'ending']) if (patch[key] !== undefined) clean[key] = number(patch[key], 3600);
    for (const key of ['openingOverride', 'endingOverride']) if (Object.hasOwn(patch, key)) {
      if (patch[key] !== null && (typeof patch[key] !== 'number' || !Number.isFinite(patch[key]) || patch[key] <= 0 || patch[key] > 3600))
        throw new AppError('INVALID_ARGUMENT', '片头片尾时长需为 0–3600 秒');
      clean[key] = patch[key];
    }
    for (const key of ['autoOpening', 'autoEnding']) if (typeof patch[key] === 'boolean') clean[key] = patch[key];
    if (['auto', 'manual'].includes(patch.skipMode)) clean.skipMode = patch.skipMode;
    for (const key of ['subtitleDelay', 'audioDelay']) if (patch[key] !== undefined) clean[key] = Math.max(-60, Math.min(60, Number(patch[key]) || 0));
    for (const key of ['audioLanguage', 'subtitleLanguage']) if (typeof patch[key] === 'string') clean[key] = patch[key].slice(0, 50);
    await this.store.update((data) => {
      guard();
      if (typeof clean.autoOpening === 'boolean' || typeof clean.autoEnding === 'boolean')
        data.autoIntroSkip = clean.autoOpening !== false && clean.autoEnding !== false;
      const target = scope === 'series' ? data.series : data.episodes;
      const key = scope === 'series' ? seriesKey(request) : episodePreferenceKey(request);
      if (Object.hasOwn(clean, 'danmaku')) {
        const episodeKey = episodePreferenceKey(request);
        const previous = data.episodes[episodeKey]?.danmaku;
        if (clean.danmaku && previous?.url === clean.danmaku.url) {
          // The desktop may save a display name after loading a local file.
          // Keep the durable payload and provider routing for that same URL.
          for (const field of ['cacheId', 'sourceId', 'standalone'])
            if (clean.danmaku[field] === undefined && previous[field] !== undefined) clean.danmaku[field] = previous[field];
        }
        const previousWrite = this.danmakuWrites.get(previous?._selection);
        if (previousWrite?.state === 'pending') previousWrite.state = 'cancelled';
        if (danmakuWrite) {
          danmakuWrite.previous = previous;
          danmakuWrite.previousWrite = previousWrite;
          this.danmakuWrites.set(danmakuWrite.id, danmakuWrite);
          clean.danmaku = { ...clean.danmaku, _selection: danmakuWrite.id };
        }
        if (scope === 'series') {
          data.episodes[episodeKey] = { ...data.episodes[episodeKey], danmaku: clean.danmaku, updatedAt: new Date().toISOString() };
          delete clean.danmaku;
        }
      }
      if (scope === 'series' && (clean.skipSchema === 2 || Object.hasOwn(clean, 'openingOverride') || Object.hasOwn(clean, 'endingOverride'))) {
        const previous = skipPreferences({ ...effectivePreferences(data.series[key], data.episodes[episodePreferenceKey(request)]), ...clean });
        target[key] = { ...target[key], skipSchema: 2, openingOverride: previous.openingOverride, endingOverride: previous.endingOverride,
          autoOpening: previous.autoOpening, autoEnding: previous.autoEnding };
      }
      target[key] = { ...target[key], ...clean, updatedAt: new Date().toISOString() };
      if (scope === 'series') {
        // Choosing the series scope also makes this episode follow these skip
        // settings again. Unrelated subtitle/danmaku overrides stay episode scoped.
        const episode = data.episodes[episodePreferenceKey(request)];
        if (episode) for (const field of ['opening', 'ending', 'openingOverride', 'endingOverride', 'autoOpening', 'autoEnding', 'skipMode'])
          if (Object.hasOwn(clean, field)) delete episode[field];
      }
      const keys = Object.keys(target); for (const old of keys.slice(0, Math.max(0, keys.length - 3000))) delete target[old];
    });
    return this.preferences(request);
  }
  async candidates(history) {
    if (!history.identity?.key) return [];
    const data = await this.store.read();
    return Object.entries(data.bindings).filter(([, item]) => item.metadata.tmdbId === history.identity.tmdbId && item.metadata.mediaType === history.identity.mediaType)
      .map(([key, item]) => ({ key, ...item.source, title: item.metadata.title }));
  }
  async bindingByKey(key) { return (await this.store.read()).bindings[key] || null; }
}
