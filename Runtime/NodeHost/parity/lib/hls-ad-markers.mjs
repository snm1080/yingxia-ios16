// Markers only authorize complete, bounded media intervals. Unknown SCTE
// payloads and external interstitial assets do not describe in-band segments.
const maxAdDuration = 600;
const tolerance = 0.1;
const near = (left, right) => Math.abs(left - right) <= tolerance;
const number = value => /^(?:\d+(?:\.\d*)?|\.\d+)$/.test(value ?? '') ? Number(value) : NaN;
const bounded = value => Number.isFinite(value) && value > 0 && value <= maxAdDuration;

export function attributes(line) {
  const result = {};
  for (const match of line.matchAll(/(?:^|[:,])\s*([A-Z0-9-]+)=("[^"]*"|[^,]*)/gi))
    result[match[1].toUpperCase()] = match[2].replace(/^"|"$/g, '');
  return result;
}

function cueEvent(line) {
  const fields = attributes(line);
  if (/^#EXT-X-CUE-OUT-CONT(?::|$)/.test(line)) {
    const compact = line.match(/^#EXT-X-CUE-OUT-CONT:([\d.]+)\/([\d.]+)$/);
    const elapsed = number(compact?.[1] ?? fields.ELAPSEDTIME);
    const total = number(compact?.[2] ?? fields.DURATION);
    return { type: 'continue', family: 'cue', elapsed, total, duration: total - elapsed,
      invalid: !bounded(total) || !Number.isFinite(elapsed) || elapsed < 0 || elapsed >= total };
  }
  let type;
  if (/^#EXT-X-(?:CUE|SCTE35)-OUT(?::|$)/.test(line)) type = 'out';
  else if (/^#EXT-X-(?:CUE|SCTE35)-IN(?::|$)/.test(line)) type = 'in';
  else if (line.startsWith('#EXT-X-SCTE35:') && /^(?:OUT|IN)$/i.test(fields.TYPE ?? '')) type = fields.TYPE.toLowerCase();
  if (!type) return null;
  const value = line.match(/^#EXT-X-(?:CUE|SCTE35)-OUT:([\d.]+)$/)?.[1] ?? fields.DURATION;
  const duration = number(value);
  return { type, family: line.startsWith('#EXT-X-CUE-') ? 'cue' : 'scte',
    duration, invalid: value !== undefined && !bounded(duration) };
}

function uniqueBoundary(offsets, target, minimum = 0) {
  let match;
  for (let index = minimum; index < offsets.length; index++) {
    if (near(offsets[index], target)) {
      if (match !== undefined) return undefined;
      match = index;
    }
    if (offsets[index] > target + tolerance) break;
  }
  return match;
}

function cueRanges(groups, offsets) {
  const ranges = [];
  const durationEnd = range => {
    if (range.invalid || !bounded(range.duration)) return undefined;
    const end = uniqueBoundary(offsets, offsets[range.start] + range.duration, range.start + 1);
    return end !== undefined && bounded(offsets[end] - offsets[range.start]) ? end : undefined;
  };
  let active = null;
  for (const [index, tags] of groups) {
    for (const tag of tags) {
      const event = cueEvent(tag.line);
      if (!event) continue;
      if (event.type === 'out') {
        // A publisher may signal one splice with both CUE and SCTE tags.
        // Matching positions can share a range only when durations agree.
        if (active && active.start === index && !active.continuation && !active.families.has(event.family)) {
          if (event.invalid || Number.isFinite(active.duration) && Number.isFinite(event.duration) &&
              active.duration !== event.duration) active.invalid = true;
          if (!Number.isFinite(active.duration)) active.total = active.duration = event.duration;
          active.families.add(event.family);
          active.markers.push(tag.index);
          continue;
        }
        if (active) {
          const end = durationEnd(active);
          if (end === undefined || end > index) { active.invalid = true; continue; }
          active.end = end;
          ranges.push(active);
        }
        active = { start: index, duration: event.duration, total: event.duration,
          initialElapsed: 0, invalid: event.invalid, families: new Set([event.family]), markers: [tag.index] };
      } else if (event.type === 'continue') {
        if (!active) {
          active = { start: index, duration: event.duration, total: event.total,
            initialElapsed: event.elapsed, invalid: event.invalid, continuation: true,
            families: new Set([event.family]), markers: [tag.index] };
          continue;
        }
        active.markers.push(tag.index);
        active.continuation = true;
        const spent = offsets[index] - offsets[active.start];
        if (event.invalid || !near(active.initialElapsed + spent, event.elapsed) ||
            Number.isFinite(active.total) && !near(active.total, event.total)) active.invalid = true;
        if (!Number.isFinite(active.total)) {
          active.total = event.total;
          active.duration = event.total - active.initialElapsed;
        }
      } else if (active) {
        active.end = index;
        active.closedFamilies = new Set([event.family]);
        active.markers.push(tag.index);
        ranges.push(active);
        active = null;
      } else {
        const previous = ranges.at(-1);
        if (previous?.end === index && previous.families.has(event.family) &&
            previous.closedFamilies && !previous.closedFamilies.has(event.family)) {
          previous.closedFamilies.add(event.family);
          previous.markers.push(tag.index);
        }
      }
    }
  }
  if (active) ranges.push(active);
  return ranges.filter(range => {
    if (range.invalid) return false;
    if (range.end === undefined) {
      range.end = durationEnd(range);
    }
    if (range.end === undefined || range.end <= range.start) return false;
    const actual = offsets[range.end] - offsets[range.start];
    // Explicit CUE IN remains the actual end of an ordinary paired cue. A
    // continuation also asserts elapsed time, so its remaining time must agree.
    return bounded(actual) && (!range.continuation || near(actual, range.duration));
  });
}

function timestamp(value) {
  // Requiring a timezone avoids machine-local interpretation of malformed tags.
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/i.test(value ?? '')) return NaN;
  return Date.parse(value) / 1000;
}

function dateRanges(groups, offsets) {
  const records = new Map(), origins = [];
  for (const [index, tags] of groups) {
    for (const tag of tags) {
      if (tag.line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        // A tail tag has no following media segment to timestamp.
        if (index < offsets.length - 1) origins.push(timestamp(tag.line.slice('#EXT-X-PROGRAM-DATE-TIME:'.length)) - offsets[index]);
      }
      if (!tag.line.startsWith('#EXT-X-DATERANGE:')) continue;
      const fields = attributes(tag.line);
      if (!fields.ID) continue;
      if (!records.has(fields.ID)) records.set(fields.ID, { fields: {}, markers: [], invalid: false });
      const record = records.get(fields.ID);
      record.markers.push(tag.index);
      const names = [...tag.line.matchAll(/(?:^|[:,])\s*([A-Z0-9-]+)=("[^"]*"|[^,]*)/gi)].map(match => match[1].toUpperCase());
      if (new Set(names).size !== names.length) record.invalid = true;
      for (const [name, value] of Object.entries(fields)) {
        if (record.fields[name] !== undefined && record.fields[name] !== value) record.invalid = true;
        record.fields[name] = value;
      }
    }
  }
  if (!origins.length || origins.some(origin => !Number.isFinite(origin) || !near(origin, origins[0]))) return [];
  const ranges = [];
  for (const record of records.values()) {
    const fields = record.fields;
    if (record.invalid || fields['X-ASSET-URI'] !== undefined || fields['X-ASSET-LIST'] !== undefined ||
        /^com\.apple\.hls\.interstitial(?:$|[.\-])/i.test(fields.CLASS ?? '')) continue;
    if (!fields['SCTE35-OUT'] && !/(?:^|[.\/_-])(?:ad|ads|advertisement|adbreak)(?:$|[.\/_-])/i.test(fields.CLASS ?? '')) continue;
    const startTime = timestamp(fields['START-DATE']);
    const duration = number(fields.DURATION);
    let endTime = timestamp(fields['END-DATE']);
    if (!Number.isFinite(startTime) || fields.DURATION !== undefined && !bounded(duration) ||
        fields['END-DATE'] !== undefined && !Number.isFinite(endTime)) continue;
    if (Number.isFinite(endTime) && Number.isFinite(duration) && !near(endTime - startTime, duration)) continue;
    if (!Number.isFinite(endTime)) endTime = startTime + duration;
    if (!bounded(endTime - startTime)) continue;
    const start = uniqueBoundary(offsets, startTime - origins[0]);
    const end = uniqueBoundary(offsets, endTime - origins[0]);
    if (start === undefined || end === undefined || end <= start || !bounded(offsets[end] - offsets[start])) continue;
    // All independent clocks must select the same segment boundaries.
    if (origins.some(origin => uniqueBoundary(offsets, startTime - origin) !== start ||
        uniqueBoundary(offsets, endTime - origin) !== end)) continue;
    ranges.push({ start, end, markers: record.markers });
  }
  return ranges;
}

function consistentRanges(ranges) {
  // All marker formats must agree on overlapping windows. Conflicts cannot
  // authorize the union: doing so can remove program segments outside a cue.
  for (let left = 0; left < ranges.length; left++) {
    for (let right = left + 1; right < ranges.length; right++) {
      const a = ranges[left], b = ranges[right];
      if (a.start < b.end && b.start < a.end && (a.start !== b.start || a.end !== b.end)) a.invalid = b.invalid = true;
    }
  }
  return ranges.filter(range => !range.invalid);
}

export function markedAds(parsed) {
  const removed = new Set(), markers = new Set(), offsets = [0];
  for (const entry of parsed.entries) offsets.push(offsets.at(-1) + entry.duration);
  const groups = [...parsed.entries.map(entry => [entry.index, entry.tags]), [parsed.entries.length, parsed.tail]];
  const ranges = consistentRanges([...cueRanges(groups, offsets), ...dateRanges(groups, offsets)]);
  for (const range of ranges) {
    for (let index = range.start; index < range.end; index++) removed.add(index);
    for (const marker of range.markers) markers.add(marker);
  }
  return { removed, markers };
}
