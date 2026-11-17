import { episodeNumbers, isEpisodeExtra } from './episode-numbers.mjs';

export function tmdbQuery(title) {
  let raw = String(title || '').normalize('NFKC').replace(/<[^>]*>/g, ' ')
    .replace(/[\p{So}\p{Cf}]/gu, ' ').trim()
    .replace(/^(?:[\[【](?:国剧|泰剧|韩剧|日剧|美剧|短剧|电视剧|剧集|电影|标题)[\]】]\s*[:：]?\s*|(?:电视剧|剧集|电影)\s*[:：]\s*|国剧(?=[\p{Script=Han}「『]))/u, '');
  // Resource catalogs conventionally put the release year before their cast,
  // genre and encoding descriptions. Keep a colon subtitle as part of a title.
  const year = raw.match(/[\[【(]\s*(?:19|20)\d{2}\s*[\]】)]/);
  if (year?.index > 0 && !/^\s*[:：]/.test(raw.slice(year.index + year[0].length))) raw = raw.slice(0, year.index);
  const book = raw.match(/^《([^》]+)》/);
  if (book) raw = book[1];
  const tail = raw.search(/(?:更新至?|更至?|连载至|連載至|全|共)\s*(?:EP?)?\d+(?:\s*[-~至]\s*\d+)?\s*[集话話期]?|(?<=[\p{Script=Han}\s._-])(?:4K|8K|2160p|1080p|720p|WEB[- ]?DL|HDR|SDR|HEVC|H\.?26[45]|x26[45])|[\[【(](?:剧情|爱情|古装|都市|悬疑|国安|喜剧|动作|科幻|犯罪)[^\]】)]*[\]】)]/iu);
  if (tail > 0) raw = raw.slice(0, tail);
  raw = raw.replace(/^[「『]+|[\s「『\[【(]+$/g, '');
  return raw
    .replace(/\.(?:mkv|mp4|avi|mov|wmv|flv|rmvb|ts|m2ts)$/i, ' ')
    .replace(/[\[【(]([^\]】)]*)[\]】)]/g, (all, inner) => /^(?:19|20)\d{2}$|\b(?:4K|8K|HDR|HD|UHD|1080p|2160p|720p|BluRay|WEB-DL|\d+(?:\.\d+)?fps)\b|(?:DTS|AAC|AC3|DDP)音轨|(?:更新至|更|全)\s*\d+\s*集|高码率|字幕|中字|国语|粤语|国粤|配音|高清|超清|完整版/i.test(inner) ? ' ' : all)
    .replace(/[\[【(]\s*(?:真彩|臻彩|无水印|无台标)\s*[\]】)]/g, ' ')
    .replace(/第\s*[零〇一二两三四五六七八九十百千\d]+\s*[季集]|\bSeason\s*\d{1,3}\b|\bS\d{1,3}(?:[ ._-]*E\d{1,4})?\b/gi, ' ')
    .replace(/\b(?:2160p|1080p|720p|WEB[- ]?DL|BluRay|HEVC|H\.?26[45]|x26[45]|AAC|DTS|DDP|Atmos)\b/gi, ' ')
    .replace(/(?:\s*(?:\b(?:4K|8K|HDR|HD|UHD|1080p|2160p|720p|BluRay|WEB-DL)\b|更新至\s*\d+\s*集|全\s*\d+\s*集|高码率|国语版|粤语版|国粤双语|中英双字|简繁中字|高清版|超清版|完整版|完结))+\s*$/gi, ' ')
    .replace(/[\p{So}]/gu, ' ').replace(/[#＃]/g, '')
    .replace(/(^|\s)(?:动漫|动画|电视剧|剧集|电影|综艺)(?=\s|$)/g, ' ')
    .replace(/[._]+/g, ' ').replace(/\s+/g, ' ').trim()
    .replace(/^[a-z]\s+(?=.*[\p{Script=Han}])/iu, '')
    .replace(/(?<=[\p{Script=Han}].*)\s+[a-z]$/iu, '')
    .trim().slice(0, 200);
}

// Keep release-year evidence separate from the cleaned title. A year directly
// before SxxExx is a release label; arbitrary numbers in a title are not.
export function tmdbSourceYear(year, title, episodeNames = []) {
  const explicit = String(year || '').match(/(?:19|20)\d{2}/)?.[0];
  if (explicit) return explicit;
  const bracketed = String(title || '').normalize('NFKC').match(/[\[【(]\s*((?:19|20)\d{2})\s*[\]】)]/)?.[1];
  if (bracketed) return bracketed;
  const years = new Set(episodeNames.map(name => String(name).match(/(?:^|[ ._-])((?:19|20)\d{2})(?=[ ._-]+S\d+[ ._-]*E\d+)/i)?.[1]).filter(Boolean));
  return years.size === 1 ? [...years][0] : undefined;
}

export const titleKey = value => tmdbQuery(value).toLocaleLowerCase().replace(/[\p{P}\p{S}\s]/gu, '');

export function pickTmdbMatch(items, { title, year, mediaType } = {}) {
  const keys = [title, ...String(title || '').split(/\s*[\/|／]\s*/)].map(titleKey).filter(Boolean);
  let matches = items.filter(item => [item.title, item.originalTitle].some(value => keys.includes(titleKey(value))));
  if (mediaType === 'movie' || mediaType === 'tv') matches = matches.filter(item => item.mediaType === mediaType);
  const sourceYear = String(year || '').match(/(?:19|20)\d{2}/)?.[0];
  // A second season is usually newer than the series' first_air_date.
  if (sourceYear && !(episodeNumbers(title).season > 1)) {
    const sameYear = matches.filter(item => item.year === sourceYear);
    if (sameYear.length) matches = sameYear;
    else matches = matches.filter(item => !item.year);
  }
  // Repeated names/remakes require a user choice; popularity is not identity.
  return matches.length === 1 ? matches[0] : null;
}

export function tmdbEpisodePlan(names, { title, flag, seasons, mapping } = {}) {
  const known = Array.isArray(seasons) ? seasons : [];
  const defaultSeason = mapping?.season ?? episodeNumbers(flag).season ?? episodeNumbers(title).season
    ?? known.find(season => season.number === 1)?.number ?? known.find(season => season.number > 0)?.number ?? 0;
  const plan = names.map(name => {
    if (isEpisodeExtra(name)) return null;
    const numbers = episodeNumbers(name);
    if (mapping?.season !== undefined && numbers.season !== null && numbers.season !== mapping.season) return null;
    const season = numbers.season ?? defaultSeason;
    if (!known.some(item => item.number === season)) return null;
    return { season, number: numbers.episode === null ? null : numbers.episode + (mapping?.offset || 0) };
  });
  // Some sources keep a continuous episode count across seasons. Apply an
  // offset only for an explicit season and a range beginning at that boundary.
  if (!mapping && defaultSeason > 1 && (episodeNumbers(title).season !== null || episodeNumbers(flag).season !== null)) {
    const count = known.find(item => item.number === defaultSeason)?.episodeCount || 0;
    const previous = known.filter(item => item.number > 0 && item.number < defaultSeason);
    const offset = previous.reduce((sum, item) => sum + item.episodeCount, 0);
    const numbered = plan.filter(item => item?.season === defaultSeason && item.number !== null);
    if (count && previous.length === defaultSeason - 1 && previous.every(item => item.episodeCount > 0)
      && numbered.length && Math.min(...numbered.map(item => item.number)) === offset + 1
      && numbered.every(item => item.number <= offset + count)) {
      for (const item of numbered) item.number -= offset;
    }
  }
  return plan;
}
