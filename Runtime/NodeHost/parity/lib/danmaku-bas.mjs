// Parse the declarative BAS text/path language. This deliberately has no eval,
// script host, network access or event handlers. Unsupported programs are skipped.
const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const numeric = (value, fallback = 0, axis = 1) => {
  if (typeof value === 'object' && value?.unit === '%') return value.value * axis / 100;
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
};
const seconds = value => typeof value === 'object' && value?.unit === 'ms' ? value.value / 1000
  : typeof value === 'object' && value?.unit === 's' ? value.value : numeric(value);

function tokens(source) {
  const result = [];
  const pattern = /\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:0x[\da-f]+|[-+]?(?:\d*\.\d+|\d+)(?:e[-+]?\d+)?)(?:ms|s|%)?|[A-Za-z_$][\w$]*|[{}=;:,()]/giy;
  let at = 0;
  while (at < source.length) {
    pattern.lastIndex = at;
    const found = pattern.exec(source);
    if (!found) throw new Error('Unsupported BAS expression');
    const token = found[0]; at = pattern.lastIndex;
    if (/^\s|^\/\//.test(token) || token.startsWith('/*')) continue;
    result.push(token);
    if (result.length > 16000) throw new Error('BAS program is too large');
  }
  return result;
}

function stringValue(value) {
  if (value[0] === '"') return JSON.parse(value);
  return value.slice(1, -1).replace(/\\(u[\da-f]{4}|n|r|t|['"\\])/gi, (_, escape) =>
    escape[0] === 'u' ? String.fromCharCode(parseInt(escape.slice(1), 16))
      : ({ n: '\n', r: '\r', t: '\t' })[escape] ?? escape);
}

// SVG's common BAS path commands map to libass vectors, including curves.
export function basDrawing(source) {
  if (typeof source !== 'string' || source.length > 16384) throw new Error('Invalid BAS path');
  const parts = source.match(/[MLHVQCZmlhvqcz]|[-+]?(?:\d*\.\d+|\d+)(?:e[-+]?\d+)?/g) || [];
  if (source.replace(/[MLHVQCZmlhvqcz]|[-+]?(?:\d*\.\d+|\d+)(?:e[-+]?\d+)?|[\s,]/g, '')) throw new Error('Unsupported BAS path');
  let i = 0, x = 0, y = 0, originX = 0, originY = 0, command;
  const output = [];
  const number = () => { const value = Number(parts[i++]); if (!Number.isFinite(value) || Math.abs(value) > 16384) throw new Error('Invalid BAS coordinate'); return value; };
  while (i < parts.length) {
    if (/^[A-Za-z]$/.test(parts[i])) command = parts[i++];
    if (!command) throw new Error('Missing path command');
    const relative = command === command.toLowerCase(), kind = command.toUpperCase();
    const point = () => [number() + (relative ? x : 0), number() + (relative ? y : 0)];
    if (kind === 'Z') { output.push('c'); x = originX; y = originY; command = null; continue; }
    if (kind === 'M' || kind === 'L') {
      [x, y] = point(); output.push(kind === 'M' ? 'm' : 'l', x, y);
      if (kind === 'M') { originX = x; originY = y; command = relative ? 'l' : 'L'; }
    } else if (kind === 'H') { x = number() + (relative ? x : 0); output.push('l', x, y); }
    else if (kind === 'V') { y = number() + (relative ? y : 0); output.push('l', x, y); }
    else if (kind === 'C') { const first = point(), second = point(), end = point(); output.push('b', ...first, ...second, ...end); [x, y] = end; }
    else if (kind === 'Q') {
      const control = point(), end = point();
      output.push('b', x + (control[0] - x) * 2 / 3, y + (control[1] - y) * 2 / 3,
        end[0] + (control[0] - end[0]) * 2 / 3, end[1] + (control[1] - end[1]) * 2 / 3, ...end);
      [x, y] = end;
    }
    if (output.length > 4096) throw new Error('BAS path is too large');
  }
  if (!output.length) throw new Error('Empty BAS path');
  return output.map(value => typeof value === 'number' ? Math.round(value * 1000) / 1000 : value).join(' ');
}

function state(attributes, previous = {}) {
  const value = { ...previous };
  for (const [name, axis, fallback, min, max] of [
    ['x', 1280, 0, -8192, 8192], ['y', 720, 0, -8192, 8192],
    ['fontSize', 720, 25, 1, 512], ['rotateZ', 1, 0, -3600, 3600], ['rotateY', 1, 0, -3600, 3600],
    ['scaleX', 1, 1, 0, 20], ['scaleY', 1, 1, 0, 20], ['anchorX', 1, 0, 0, 1], ['anchorY', 1, 0, 0, 1],
  ]) value[name] = clamp(numeric(attributes[name], previous[name] ?? fallback, axis), min, max);
  value.opacity = clamp(numeric(attributes.alpha, previous.opacity ?? 1), 0, 1);
  value.color = clamp(numeric(attributes.color ?? attributes.fillColor, previous.color ?? 0xffffff), 0, 0xffffff);
  return value;
}

export function parseBas(source) {
  try {
    if (typeof source !== 'string' || source.length > 65536) return null;
    const stream = tokens(source), definitions = new Map();
    let at = 0, previousEnd = 0, statements = 0;
    const take = expected => { const token = stream[at++]; if (expected && token !== expected) throw new Error('Unexpected BAS token'); return token; };
    const identifier = () => { const token = take(); if (!/^[A-Za-z_$][\w$]*$/.test(token)) throw new Error('Invalid BAS identifier'); return token; };
    const value = () => {
      const token = take();
      if (token?.[0] === '"' || token?.[0] === "'") return stringValue(token);
      if (token === 'true' || token === 'false') return token === 'true';
      const match = token?.match(/^([-+]?(?:\d*\.\d+|\d+)(?:e[-+]?\d+)?)(ms|s|%)$/i);
      if (match) return { value: Number(match[1]), unit: match[2] };
      const number = Number(token);
      if (!Number.isFinite(number)) throw new Error('BAS expressions are not executable');
      return number;
    };
    const body = () => {
      take('{'); const result = {};
      while (stream[at] !== '}') {
        const key = identifier(); take('='); result[key] = value();
        if (stream[at] === ';' || stream[at] === ',') take();
      }
      take('}'); return result;
    };
    while (at < stream.length) {
      if (stream[at] === ';') { take(); continue; }
      if (++statements > 512) throw new Error('Too many BAS statements');
      let sequential = false;
      if (stream[at] === 'then') { take(); sequential = true; }
      const command = take();
      if (command === 'def') {
        const kind = identifier(), name = identifier();
        if (!['text', 'path'].includes(kind) || definitions.has(name) || definitions.size >= 64) throw new Error('Unsupported BAS definition');
        const attributes = body();
        const base = state(attributes);
        const text = kind === 'text' ? String(attributes.content ?? '').slice(0, 4096) : '';
        const drawing = kind === 'path' ? basDrawing(attributes.d) : undefined;
        definitions.set(name, { ...base, text, ...(drawing ? { drawing } : {}),
          font: String(attributes.fontFamily ?? 'Microsoft YaHei').slice(0, 80),
          outline: attributes.bold !== false, fontWeight: attributes.bold ? 700 : 400,
          lifetime: clamp(seconds(attributes.duration) || 4, .01, 120), explicitDuration: attributes.duration !== undefined,
          frames: [], current: base });
      } else if (command === 'set') {
        const target = definitions.get(identifier());
        if (!target) throw new Error('Undefined BAS target');
        const attributes = body();
        const duration = clamp(seconds(value()), .001, 120), delay = sequential ? previousEnd : 0;
        const to = state(attributes, target.current);
        target.frames.push({ delay, duration, from: target.current, to });
        target.current = to; previousEnd = delay + duration;
        if (!target.explicitDuration) target.lifetime = Math.max(target.lifetime, previousEnd);
      } else throw new Error('Unsupported BAS command');
    }
    const items = [...definitions.values()].filter(item => item.text || item.drawing).map(({ current, explicitDuration, ...item }) => item);
    return items.length ? { text: items.map(item => item.text).filter(Boolean).join('\n') || 'BAS',
      effect: { kind: 'bas', lifetime: Math.max(...items.map(item => item.lifetime)), items } } : null;
  } catch { return null; }
}
