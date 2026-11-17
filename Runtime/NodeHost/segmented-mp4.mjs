import { fetchResponse } from './parity/lib/http.mjs';

const prefixBytes = 64 * 1024;
const maximumBytes = 512 * 1024;
const maximumReferences = 20000;

// Inspect complete boxes only. A regular MP4 or incomplete, large or
// hierarchical index stays on the existing whole-resource path.
export function inspectSegmentedMP4(bytes) {
  let offset = 0, movie = false;
  const safe = value => value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : NaN;
  while (offset + 8 <= bytes.length) {
    let size = bytes.readUInt32BE(offset), header = 8;
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if (size === 1) {
      if (offset + 16 > bytes.length) return { need: offset + 16 };
      size = safe(bytes.readBigUInt64BE(offset + 8)); header = 16;
    }
    if (!Number.isSafeInteger(size) || size < header || offset + size > maximumBytes
      || ['mdat', 'moof', 'pssh'].includes(type)) return null;
    if (offset + size > bytes.length) return { need: offset + size };
    if (type === 'moov') movie = true;
    if (type === 'sidx') {
      const end = offset + size;
      if (!movie || size < header + 24) return null;
      const version = bytes[offset + header];
      if (version > 1) return null;
      const timescale = bytes.readUInt32BE(offset + header + 8);
      let cursor = offset + header + 12;
      const width = version === 0 ? 4 : 8;
      if (!timescale || cursor + width * 2 + 4 > end) return null;
      const number = at => width === 4 ? bytes.readUInt32BE(at) : safe(bytes.readBigUInt64BE(at));
      let time = number(cursor); const firstOffset = number(cursor + width); cursor += width * 2;
      const count = bytes.readUInt16BE(cursor + 2); cursor += 4;
      if (!Number.isSafeInteger(time) || !Number.isSafeInteger(firstOffset)
        || !count || count > maximumReferences || cursor + count * 12 !== end) return null;
      let start = end + firstOffset;
      const segments = [];
      for (let index = 0; index < count; index++, cursor += 12) {
        const word = bytes.readUInt32BE(cursor), duration = bytes.readUInt32BE(cursor + 4);
        const length = word & 0x7fffffff;
        if (word >>> 31 || !length || !duration || !Number.isSafeInteger(start + length)
          || !Number.isSafeInteger(time + duration)) return null;
        segments.push({ start, end: start + length - 1, time, duration });
        start += length; time += duration;
      }
      return { initializationEnd: offset - 1, timescale, segments };
    }
    offset += size;
  }
  return offset < maximumBytes ? { need: offset + 8 } : null;
}

export async function segmentedMP4Index(address, headers, signal, duration) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('index inspection timeout')), 3500);
  timer.unref?.();
  const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
  let release;
  try {
    const result = await fetchResponse(address, { headers: { ...headers, Range: `bytes=0-${maximumBytes - 1}` },
      signal: combined, timeoutMs: 3500, allowInsecureRedirect: true });
    release = result.release;
    const response = result.response;
    if (!response.ok || !response.body) return null;
    // Some authenticated proxies answer 200 with a valid start-at-zero range.
    // Without Content-Range, 200 still starts at zero, but is never read unbounded.
    const range = response.headers.get('content-range');
    if (response.status === 206 && !range) return null;
    if (range && !/^bytes 0-\d+\/\d+$/.test(range)) return null;
    const total = Number(range?.split('/')[1] || (response.status === 200 ? response.headers.get('content-length') : 0));
    const complete = async (index, consumed) => {
      if (!index?.segments) return null;
      // Some files place a local SIDX before every fragment. That first index
      // must not replace the movie with only its first second. A known duration
      // verifies the whole timeline; absent it require coverage to file end.
      const indexedDuration = index.segments.reduce((sum, segment) => sum + segment.duration, 0) / index.timescale;
      const knownDuration = Number(duration);
      if (Number.isFinite(knownDuration) && knownDuration > 0
        && Math.abs(indexedDuration - knownDuration) > Math.max(0.1, Math.min(1, knownDuration * 0.001))) return null;
      const last = index.segments.at(-1).end + 1;
      if (!Number.isSafeInteger(total) || total <= 0 || last > total) return null;
      if (last === total) return index;
      const tailBytes = total - last;
      if (tailBytes > 64 * 1024 || consumed + tailBytes > maximumBytes) return null;
      // A global SIDX may be followed by an mfra index/free padding. Verify the
      // complete bounded suffix; a second sidx/moof/mdat means a local index.
      const tail = await fetchResponse(address, { headers: { ...headers, Range: `bytes=${last}-${total - 1}` },
        signal: combined, timeoutMs: 3500, allowInsecureRedirect: true });
      try {
        if (tail.response.status !== 206 || tail.response.headers.get('content-range') !== `bytes ${last}-${total - 1}/${total}`) return null;
        const pieces = []; let count = 0;
        for await (const chunk of tail.response.body) {
          count += chunk.length;
          if (count > tailBytes) return null;
          pieces.push(Buffer.from(chunk));
        }
        if (count !== tailBytes) return null;
        const bytes = Buffer.concat(pieces); let cursor = 0;
        while (cursor + 8 <= bytes.length) {
          const size = bytes.readUInt32BE(cursor), type = bytes.toString('ascii', cursor + 4, cursor + 8);
          if (!['mfra', 'free'].includes(type) || size < 8 || cursor + size > bytes.length) return null;
          cursor += size;
        }
        return cursor === bytes.length ? index : null;
      } finally { tail.release(); await tail.response.body?.cancel().catch(() => {}); }
    };
    const chunks = []; let length = 0, needed = prefixBytes;
    for await (const chunk of response.body) {
      const part = Buffer.from(chunk).subarray(0, maximumBytes - length);
      chunks.push(part); length += part.length;
      if (length >= needed) {
        const index = inspectSegmentedMP4(Buffer.concat(chunks));
        if (!index || index.segments) return await complete(index, length);
        needed = index.need;
        if (needed > maximumBytes) return null;
      }
      if (length === maximumBytes) break;
    }
    const index = inspectSegmentedMP4(Buffer.concat(chunks));
    return await complete(index, length);
  } catch { signal?.throwIfAborted(); return null; }
  finally { clearTimeout(timer); controller.abort(); release?.(); }
}

export function segmentedRepresentation(index, url, id, mime, bandwidth, xml) {
  const timeline = index.segments.map(segment => `<S t="${segment.time}" d="${segment.duration}"/>`).join('');
  const ranges = index.segments.map(segment => `<SegmentURL mediaRange="${segment.start}-${segment.end}"/>`).join('');
  // FFmpeg reads SegmentTimeline from the AdaptationSet and mediaRange from
  // the Representation's SegmentList. startNumber is the array's zero index.
  return `<AdaptationSet contentType="${id}" mimeType="${mime}"><SegmentList timescale="${index.timescale}" startNumber="0"><SegmentTimeline>${timeline}</SegmentTimeline></SegmentList><Representation id="${id}" bandwidth="${bandwidth}"><BaseURL>${xml(url)}</BaseURL><SegmentList timescale="${index.timescale}" startNumber="0"><Initialization range="0-${index.initializationEnd}"/>${ranges}</SegmentList></Representation></AdaptationSet>`;
}
