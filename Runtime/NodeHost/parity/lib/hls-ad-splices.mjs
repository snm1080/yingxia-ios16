// URL inspection is separate from output: signatures, escaping and proxy URLs
// always stay byte-for-byte intact in the media entries and rebuilt playlist.
export function detectionUri(raw) {
  try {
    let url = new URL(raw);
    for (let depth = 0; depth < 3 && /\/(?:proxy|m3u8-clean)\/?$/i.test(url.pathname); depth++) {
      const target = url.searchParams.get('url') || url.searchParams.get('source');
      if (!/^https?:\/\//i.test(target || '')) break;
      url = new URL(target);
    }
    return /^https?:$/.test(url.protocol) ? url : null;
  } catch { return null; }
}

export function explicitAdvertisement(raw) {
  const url = detectionUri(raw);
  if (!url) return false;
  let pathname = url.pathname;
  try { pathname = decodeURIComponent(pathname); } catch { /* Inspect the undecoded path if malformed. */ }
  return /(?:^|\/)(?:ads?|adv|advert|advertisement|adserver|adsegment|adbreak|guanggao)(?:[\/_.-]|$)/i.test(pathname);
}

function keyState(entry) {
  const key = entry?.key;
  if (!key || key.METHOD === 'NONE') return 'NONE';
  return JSON.stringify([key.METHOD, key.URI, key.IV ? BigInt(key.IV).toString(16) : '', key.KEYFORMAT || 'identity']);
}

export function spliceAdvertisements(parsed) {
  const removed = new Set(), totals = new Map(), blocks = [], directories = [];
  const { entries } = parsed;
  if (entries.length < 12) return removed;
  let duration = 0;
  for (const entry of entries) {
    const url = detectionUri(entry.url);
    const directory = url ? new URL('.', url).href : '';
    directories.push(directory);
    const total = totals.get(directory) || { count: 0, duration: 0 };
    total.count++; total.duration += entry.duration; duration += entry.duration;
    totals.set(directory, total);
    if (!blocks.length || blocks.at(-1).discontinuities !== entry.discontinuities)
      blocks.push({ index: blocks.length, discontinuities: entry.discontinuities, entries: [], duration: 0 });
    blocks.at(-1).entries.push(entry); blocks.at(-1).duration += entry.duration;
  }
  // The manifest may itself be hosted on the ad CDN. Infer the main directory
  // from actual media, retaining its full path so sibling assets stay distinct.
  const [main, total] = [...totals].sort((a, b) => b[1].duration - a[1].duration)[0];
  if (!main || total.count < 8 || total.duration < duration * (2 / 3)) return removed;
  const overwhelming = total.duration >= duration * .9;
  for (const block of blocks) {
    const directory = directories[block.entries[0].index];
    block.directory = block.entries.every(entry => directories[entry.index] === directory) ? directory : '';
    block.main = block.directory === main;
  }
  const candidates = blocks.filter(block => {
    const before = blocks[block.index - 1], after = blocks[block.index + 1];
    return !block.main && block.directory && block.duration <= 120
      && (!before || before.main) && (!after || after.main)
      && block.entries.every(entry => !entry.map && !entry.byteRange);
  });
  const fingerprints = new Map(), provenDirectories = new Set();
  const sameMainState = block => {
    const before = blocks[block.index - 1], after = blocks[block.index + 1];
    return before?.main && after?.main && keyState(before.entries.at(-1)) === keyState(after.entries[0]);
  };
  const mark = block => {
    for (const entry of block.entries) removed.add(entry.index);
    if (blocks[block.index - 1]?.main && blocks[block.index + 1]?.main) provenDirectories.add(block.directory);
  };
  for (const block of candidates) {
    block.clear = block.entries.every(entry => keyState(entry) === 'NONE');
    const fingerprint = JSON.stringify(block.entries.map(entry => [entry.url, entry.duration, keyState(entry)]));
    if (!fingerprints.has(fingerprint)) fingerprints.set(fingerprint, []);
    fingerprints.get(fingerprint).push(block);
    // An isolated clear asset interrupts and then resumes the same encrypted
    // movie. It need not be a byte-identical repetition of an earlier ad.
    if (overwhelming && block.clear && sameMainState(block) && blocks[block.index - 1].entries.at(-1).key?.METHOD === 'AES-128') mark(block);
  }
  for (const matches of fingerprints.values()) {
    if (matches.length >= 2 && matches.some(sameMainState)) for (const block of matches) mark(block);
  }
  for (const block of candidates) {
    if (!overwhelming || !block.clear || block.entries.length < 2 || total.count < entries.length * .9 && !provenDirectories.has(block.directory)) continue;
    const before = blocks[block.index - 1], after = blocks[block.index + 1];
    if (before && after) continue;
    const first = block.entries[0], neighbor = before?.entries.at(-1) || after?.entries[0];
    const explicitReset = first.key?.METHOD === 'NONE' && first.tags.some(tag => tag.line.startsWith('#EXT-X-KEY:'));
    // Some sites prepend the same short asset without writing redundant NONE
    // tags. For unmarked clear prefixes require stronger same-origin evidence;
    // this must not turn an ordinary CDN failover into a cut.
    const unmarkedPrefix = !before && block.duration <= 30 && total.duration >= duration * .95
      && total.count >= entries.length * .95 && new URL(block.directory).origin === new URL(main).origin;
    if (!explicitReset && neighbor?.key?.METHOD !== 'AES-128' && !unmarkedPrefix) continue;
    const occurrences = blocks.filter(item => item.entries.some(entry => directories[entry.index] === block.directory)).length;
    // Keep recurring opening/closing themes unless an interior insertion has
    // independently established this asset directory as an ad source.
    if (occurrences === 1 || provenDirectories.has(block.directory)) mark(block);
  }
  return removed;
}
