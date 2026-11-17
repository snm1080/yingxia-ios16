// Built-in conservative subset of m3u8-ad-cleaner.js. Detection never decodes,
// removes or reserializes URL query parameters: these often carry signatures.
import { spliceAdvertisements, explicitAdvertisement } from './hls-ad-splices.mjs';
import { attributes, markedAds } from './hls-ad-markers.mjs';
const globalTag = /^#(?:EXTM3U$|EXT-X-(?:VERSION|TARGETDURATION|MEDIA-SEQUENCE|DISCONTINUITY-SEQUENCE|PLAYLIST-TYPE|INDEPENDENT-SEGMENTS|START|ALLOW-CACHE):?)/;
const stateTag = /^#EXT-X-(?:KEY|MAP|BYTERANGE):/;


function absoluteUri(raw, baseUrl) {
  // Keep absolute addresses byte-for-byte intact, including encoded signatures.
  if (/^[a-z][a-z\d+.-]*:/i.test(raw)) return raw;
  try { return new URL(raw, baseUrl).toString(); } catch { return raw; }
}

function rewritePlaylist(lines, sourceUrl, rewriteUri) {
  let variant = false;
  const resolve = (raw, playlist) => {
    if (raw.includes('{$')) return raw;
    const absolute = absoluteUri(raw, sourceUrl);
    if (!/^https?:\/\//i.test(absolute)) return absolute;
    return rewriteUri ? rewriteUri(absolute, { playlist }) : absolute;
  };
  return lines.map(line => {
    if (!line.startsWith('#')) {
      const result = resolve(line, variant || /\.m3u8(?:[?#]|$)/i.test(line));
      variant = false;
      return result;
    }
    if (line.startsWith('#EXT-X-STREAM-INF:')) variant = true;
    const playlist = /^#EXT-X-(?:MEDIA|I-FRAME-STREAM-INF|RENDITION-REPORT):/.test(line);
    return line.replace(/([:,])URI=("[^"]*"|[^,]*)/g, (whole, prefix, value) => {
      const raw = value.replace(/^"|"$/g, '');
      return `${prefix}URI="${resolve(raw, playlist)}"`;
    });
  }).join('\n') + '\n';
}

function mediaEntries(lines, sourceUrl) {
  const headers = [], entries = [], pending = [];
  let key = null, map = null, previousRange = null, discontinuities = 0;
  let sequence = 0n, discontinuitySequence = 0n, invalid = false;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (globalTag.test(line)) {
      headers.push(line);
      try {
        if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) sequence = BigInt(line.split(':')[1]);
        if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) discontinuitySequence = BigInt(line.split(':')[1]);
      } catch { invalid = true; }
      continue;
    }
    if (line === '#EXT-X-ENDLIST') continue;
    if (line.startsWith('#')) {
      pending.push({ line, index });
      if (line === '#EXT-X-DISCONTINUITY') discontinuities++;
      if (line.startsWith('#EXT-X-KEY:')) {
        const fields = attributes(line);
        if (!['NONE', 'AES-128'].includes(fields.METHOD) ||
            fields.KEYFORMAT && fields.KEYFORMAT !== 'identity' ||
            fields.METHOD === 'AES-128' && (!fields.URI || fields.IV && !/^0x[\da-f]{1,32}$/i.test(fields.IV))) invalid = true;
        key = { line, ...fields };
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        const fields = attributes(line);
        // Encrypted init sections need an explicit IV. An implicit map range
        // cannot be reconstructed reliably once its predecessor is removed.
        if (!fields.URI || fields.BYTERANGE && !/^\d+@\d+$/.test(fields.BYTERANGE) ||
            key?.METHOD === 'AES-128' && !key.IV) invalid = true;
        map = { line, key };
      }
      continue;
    }
    const tags = pending.splice(0);
    const durations = tags.filter(tag => tag.line.startsWith('#EXTINF:'));
    const duration = Number(durations[0]?.line.match(/^#EXTINF:([\d.]+),/)?.[1]);
    if (durations.length !== 1 || !Number.isFinite(duration) || duration <= 0) invalid = true;
    const url = absoluteUri(line, sourceUrl);
    let byteRange = null;
    const ranges = tags.filter(tag => tag.line.startsWith('#EXT-X-BYTERANGE:'));
    if (ranges.length) {
      const match = ranges[0].line.match(/^#EXT-X-BYTERANGE:(\d+)(?:@(\d+))?$/);
      if (ranges.length !== 1 || !match || BigInt(match[1]) <= 0n) invalid = true;
      else {
        const offset = match[2] !== undefined ? BigInt(match[2]) : previousRange?.url === url ? previousRange.end : null;
        if (offset === null) invalid = true;
        else {
          byteRange = `#EXT-X-BYTERANGE:${match[1]}@${offset}`;
          previousRange = { url, end: offset + BigInt(match[1]) };
        }
      }
    } else previousRange = null;
    entries.push({ uri: line, url, duration, tags, key, map, byteRange, discontinuities, index: entries.length });
  }
  if (pending.some(tag => /^(?:#EXTINF:|#EXT-X-BYTERANGE:)/.test(tag.line))) invalid = true;
  if (sequence < 0n || discontinuitySequence < 0n || discontinuities > 1000) invalid = true;
  return { headers, entries, tail: pending, sequence, discontinuitySequence, invalid };
}


function adEntries(parsed) {
  const { removed, markers } = markedAds(parsed);
  for (const index of spliceAdvertisements(parsed)) removed.add(index);
  for (const entry of parsed.entries) if (explicitAdvertisement(entry.url)) removed.add(entry.index);
  return { removed, markers };
}

function rebuild(parsed, removed, markers) {
  const kept = parsed.entries.filter(entry => !removed.has(entry.index));
  const first = kept[0];
  const headers = parsed.headers.filter(line => !/^#EXT-X-(?:MEDIA-SEQUENCE|DISCONTINUITY-SEQUENCE):/.test(line));
  headers.push(`#EXT-X-MEDIA-SEQUENCE:${parsed.sequence + BigInt(first.index)}`);
  if (parsed.discontinuitySequence || first.discontinuities || parsed.headers.some(line => line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')))
    headers.push(`#EXT-X-DISCONTINUITY-SEQUENCE:${parsed.discontinuitySequence + BigInt(first.discontinuities)}`);
  const output = [...headers];
  let lastKey = null, lastMap = null, previous = null;
  const emitKey = (key, index) => {
    let line = key?.line ?? null;
    if (key?.METHOD === 'AES-128' && !key.IV)
      line += `,IV=0x${(parsed.sequence + BigInt(index)).toString(16).padStart(32, '0')}`;
    if (line !== lastKey && line) output.push(line);
    lastKey = line;
  };
  for (const entry of kept) {
    if (previous) {
      const count = Math.max(entry.discontinuities - previous.discontinuities, entry.index !== previous.index + 1 ? 1 : 0);
      for (let index = 0; index < count; index++) output.push('#EXT-X-DISCONTINUITY');
    }
    if (entry.map && entry.map !== lastMap) {
      emitKey(entry.map.key, entry.index);
      output.push(entry.map.line);
      lastMap = entry.map;
    }
    emitKey(entry.key, entry.index);
    for (const tag of entry.tags) {
      if (stateTag.test(tag.line) || tag.line === '#EXT-X-DISCONTINUITY' || markers.has(tag.index)) continue;
      output.push(tag.line);
    }
    if (entry.byteRange) output.push(entry.byteRange);
    output.push(entry.uri);
    previous = entry;
  }
  output.push(...parsed.tail.filter(tag => !stateTag.test(tag.line) && tag.line !== '#EXT-X-DISCONTINUITY' && !markers.has(tag.index)).map(tag => tag.line));
  output.push('#EXT-X-ENDLIST');
  return output;
}

export function cleanHlsPlaylist(content, sourceUrl, { enabled = true, rewriteUri } = {}) {
  const original = Buffer.isBuffer(content) ? content.toString('utf8') : String(content ?? '');
  if (!original.trimStart().startsWith('#EXTM3U')) return { content: original, removedSegments: 0, skippedReason: 'not-hls' };
  const lines = original.replace(/^\uFEFF/, '').split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  let output = lines, removedSegments = 0, skippedReason = '';
  if (!enabled) skippedReason = 'disabled';
  else if (lines.some(line => /^#EXT-X-(?:STREAM-INF|I-FRAME-STREAM-INF|MEDIA):/.test(line))) skippedReason = 'master';
  else if (!lines.includes('#EXT-X-ENDLIST')) skippedReason = 'live';
  else if (lines.some(line => /^#EXT-X-(?:PART|PART-INF|PRELOAD-HINT|SKIP|DEFINE|RENDITION-REPORT):/.test(line))) skippedReason = 'unsupported';
  else {
    const parsed = mediaEntries(lines, sourceUrl);
    if (parsed.invalid) skippedReason = 'ambiguous';
    else {
      const { removed, markers } = adEntries(parsed);
      if (removed.size && removed.size < parsed.entries.length) {
        output = rebuild(parsed, removed, markers);
        removedSegments = removed.size;
      } else if (removed.size) skippedReason = 'all-segments';
    }
  }
  return { content: rewritePlaylist(output, sourceUrl, rewriteUri), removedSegments, skippedReason };
}
