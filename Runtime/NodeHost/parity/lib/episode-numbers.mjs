export function chineseNumber(value) {
  const text = String(value ?? '').normalize('NFKC').trim();
  if (!text) return null;
  const digits = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 兩: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const units = { 十: 10, 百: 100, 千: 1000, 万: 10000, 萬: 10000 };
  let total = 0, section = 0, digit = 0;
  for (const char of text) {
    const value = /\d/.test(char) ? Number(char) : digits[char];
    if (value !== undefined) digit = digit * 10 + value;
    else if (units[char] === 10000) { total += (section + digit || 1) * 10000; section = digit = 0; }
    else if (char in units) { section += (digit || 1) * units[char]; digit = 0; }
    else return null;
  }
  const result = total + section + digit;
  return Number.isSafeInteger(result) ? result : null;
}

const numeral = '[零〇一二两兩三四五六七八九十百千万萬\\d]+';
const chineseSeason = new RegExp(`第\\s*(${numeral})\\s*[季部]`, 'u');
const chineseEpisode = new RegExp(`(?:第\\s*)?(${numeral})\\s*[集话話期回章节節]`, 'u');
const seasonTag = /(?:\bSeason[ ._-]*|(?<![a-z\d])S[ ._-]*)(\d{1,3})(?!\d)/i;
const seasonEpisode = /S[ ._-]*(\d{1,3})[ ._-]*E(?:P)?[ ._-]*(\d{1,4})(?!\d)/i;
const episodeTag = /(?<![a-z])(?:EP(?:ISODE)?S?|E)[ ._:#-]*(\d{1,4})(?!\d)/i;
const episodeRange = new RegExp(`(?=(?:第\\s*|(?<![a-z])(?:EP(?:ISODE)?S?|E|SP)[ ._-]*|S[ ._-]*\\d+[ ._-]*E)(${numeral})(?:\\s*[集话話期回章节節])?[ ._]*[-~～至][ ._]*(?:(?:第|EP?|SP)\\s*)?(${numeral}))`, 'gi');

// Inspired by webhtv's Util.getEpisodeNumber: strip technical metadata before
// interpreting loose filename numbers, and keep explicit season/episode tags.
// https://github.com/Silent1566/webhtv/blob/ce4df05d3a8cb941ce4f09007af87b52ec191046/app/src/main/java/com/fongmi/android/tv/utils/Util.java
function episodeText(name) {
  return String(name ?? '').normalize('NFKC').replace(/[\u200b-\u200d\ufeff]/g, '')
    .replace(/<[^>]*>|&nbsp;|&#160;/gi, ' ')
    .replace(/\.(?:mp4|mkv|m4v|avi|flv|m2ts|mts|ts|m3u8|webm|mov|wmv|rmvb|rm|mp3|m4a|aac|flac|wav|ogg)(?![a-z\d])/gi, ' ')
    .replace(/(?<!\d)(?:19|20)\d{2}[-_./年](?:0?[1-9]|1[0-2])[-_./月](?:0?[1-9]|[12]\d|3[01])日?(?!\d)/g, ' ')
    .replace(/(?<![a-z\d])\d+(?:\.\d+)?\s*(?:[kmgt]i?b|[gmkt])(?=$|[^a-z\d])/gi, ' ')
    .replace(/(?<![a-z\d])(?:\d{3,4}[pi](?:\d{2})?|[248]k|\d{3,4}\s*[x×]\s*\d{3,4})(?![a-z\d])/gi, ' ')
    .replace(/(?<![a-z\d])(?:[xh][ ._-]?26[45]|hevc|avc|av1|vp9|\d{1,2}[ ._-]?bit)(?![a-z\d])/gi, ' ')
    .replace(/(?<![a-z\d])(?:aac|e?ac[ ._-]?3|ddp?|dts(?:[ ._-]?hd)?|flac|truehd)(?:[ ._-]*\d\.[\d](?:ch)?)?(?![a-z\d])/gi, ' ')
    .replace(/(?<![a-z\d])(?:ver(?:sion)?|v)[ ._-]*\d+(?:\.\d+)*(?![a-z\d])/gi, ' ')
    .replace(/\s+/g, ' ').trim()
    .replace(/^[\[({【]([^\]})】]*)[\]})】]$/, '$1');
}

// Shared by playback identities and the detail page. Never infer an episode
// from its array position: sources may be reversed, incomplete or contain extras.
export function episodeNumbers(name) {
  const text = episodeText(name);
  const pair = text.match(seasonEpisode) || text.match(/(?<![a-z\d])(\d{1,3})\s*[x×]\s*(\d{1,4})(?![a-z\d])/i);
  const seasonMatch = text.match(chineseSeason) || text.match(seasonTag);
  const special = text.match(/(?:\bSP|\bSpecials?\b|特别篇|特別篇|番外(?:篇)?)[ ._-]*(\d{1,4})?(?!\d)/i);
  const season = pair ? Number(pair[1]) : seasonMatch ? chineseNumber(seasonMatch[1]) : special ? 0 : null;
  // S01E01 - 第 1 集 repeats one episode in two languages. Only distinct
  // endpoints form a range. Overlapping matches also catch a later range in
  // S01E01 - 第 1 集 - 第 3 集 instead of accepting the first repeated label.
  if ([...text.matchAll(episodeRange)].some(range => chineseNumber(range[1]) !== chineseNumber(range[2])))
    return { season, episode: null };
  if (pair) return { season, episode: Number(pair[2]) };
  const explicit = text.match(chineseEpisode) || text.match(episodeTag);
  if (explicit) return { season, episode: chineseNumber(explicit[1]) };
  if (special?.[1]) return { season, episode: Number(special[1]) };

  const loose = text.replace(chineseSeason, ' ').replace(seasonTag, ' ')
    .replace(/(?<!\d)(?:19|20)\d{2}(?!\d)/g, ' ')
    // Preserve bracketed episode numbers; discard release-group annotations.
    .replace(/[\[({【]([^\]})】]*)[\]})】]/g, (_, inner) => /^\s*\d{1,4}\s*$/.test(inner) ? ` ${inner} ` : ' ')
    .replace(/\s+/g, ' ').replace(/^[\s._]+|[\s._-]+$/g, '');
  if (/^\d{1,4}$/.test(loose)) return { season, episode: Number(loose) };
  if (/^-\d+$|^\d+\s*[-~～至]\s*\d+$/.test(loose)) return { season, episode: null };

  // Title6_01 / Title6.01 / Title6-01. A plain numeric range or decimal is
  // ambiguous; a title prefix (or an underscore) distinguishes these filenames.
  const trailing = loose.match(/(?<!\d)([1-9]\d?)([_.-])(0*[1-9]\d{0,3})(?=$|\s|[\[({【])/);
  if (trailing) {
    const prefix = loose.slice(0, trailing.index);
    const titled = /[\p{L}]/u.test(prefix);
    const suffix = loose.slice(trailing.index + trailing[0].length);
    if (!/\d/.test(suffix) && (titled || trailing[2] === '_') && (trailing[2] !== '-' || /^0\d/.test(trailing[3])))
      return { season: season ?? Number(trailing[1]), episode: Number(trailing[3]) };
  }
  // Do not merge separate numbers, or choose between competing numbers. This
  // also avoids reading a season, year, size, codec or a range as an episode.
  const numbers = loose.match(/\d+/g) || [];
  return { season, episode: numbers.length === 1 && numbers[0].length <= 4 ? Number(numbers[0]) : null };
}

export function isEpisodeExtra(name) {
  return /预告|預告|花絮|片花|采访|採訪|幕后|幕後|主题曲|主題曲|\b(?:trailer|teaser|preview|behind the scenes)\b/i.test(String(name || ''));
}
