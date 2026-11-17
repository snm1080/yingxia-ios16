import { episodeNumbers } from './episode-numbers.mjs';

const explicitEpisode = /(?<![a-z\d])(?:S[ ._-]*\d{1,3}[ ._-]*E(?:P)?[ ._-]*\d{1,4}|(?:EP(?:ISODE)?|E|SP)[ ._:#-]*\d{1,4})(?!\d)|(?:第\s*)?[零〇一二两兩三四五六七八九十百千万萬\d]+\s*[集话話期回章节節]/iu;

// Playback labels and release metadata are not subtitle search keywords.
export function subtitleSearchQuery(session) {
  const title = String(session?.title || '').trim();
  const name = String(session?.episodeName || '').trim();
  if (!title) return name;
  const identity = session?.identity;
  if (identity?.mediaType === 'movie') return title;
  const confirmed = identity?.mediaType === 'tv' && Number.isSafeInteger(identity.episode) && identity.episode > 0;
  if (!confirmed && !explicitEpisode.test(name.normalize('NFKC'))) return title;
  const { season, episode } = confirmed
    ? { season: Number.isSafeInteger(identity.season) && identity.season >= 0 ? identity.season : null, episode: identity.episode }
    : episodeNumbers(name);
  if (episode === null) return title;
  const tag = `${season === null ? '' : `S${String(season).padStart(2, '0')}`}E${String(episode).padStart(2, '0')}`;
  return `${title} ${tag}`;
}
