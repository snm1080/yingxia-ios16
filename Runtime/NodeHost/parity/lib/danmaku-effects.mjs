import { parseBas } from './danmaku-bas.mjs';

const bounded = (value, fallback, min, max) => {
  const number = Number(value);
  return value !== null && value !== '' && Number.isFinite(number) ? Math.max(min, Math.min(max, number)) : fallback;
};
const shortText = (value, length = 24) => Array.from(String(value ?? '').replace(/[\u0000-\u001f]/g, ' ')).slice(0, length).join('');
function object(value) {
  if (typeof value === 'string' && value.length <= 16384) {
    try { value = JSON.parse(value); } catch { return {}; }
  }
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}
function rgb(value, fallback) {
  if (typeof value === 'string' && /^(?:#|0x)[\da-f]{6}$/i.test(value)) return parseInt(value.replace(/^(#|0x)/i, ''), 16);
  return Math.round(bounded(value, fallback, 0, 0xffffff));
}

export function danmakuEffect(mode, message, metadata = {}) {
  metadata = object(metadata);
  if (Number(mode) === 8) return { text: '' };
  if (Number(mode) === 9) return parseBas(message) || { text: '' };
  // Bilibili mode 7 stores its text, position, opacity, rotation and motion in
  // a JSON array. Do not flatten it to a scrolling JSON string.
  if (Number(mode) === 7) {
    let values = message;
    try { if (typeof values === 'string') values = JSON.parse(values); } catch { /* Fall back to readable text. */ }
    if (Array.isArray(values) && values.length >= 5) {
      const coordinate = (value, axis) => {
        const number = bounded(value, 0, -4096, 4096);
        return number >= 0 && number <= 1 ? number * (axis ? 720 : 1280) : number * (axis ? 720 / 438 : 1280 / 672);
      };
      const opacity = String(values[2] ?? '1').split('-');
      const lifetime = bounded(values[3], 4, .1, 60);
      const path = typeof values[14] === 'string' ? [...values[14].matchAll(/[ML]\s*([-+]?\d*\.?\d+)\s*[, ]\s*([-+]?\d*\.?\d+)/gi)]
        .slice(0, 512).map(match => ({ x: Number(match[1]) * 1280 / 672, y: Number(match[2]) * 720 / 438 })) : [];
      return { text: String(values[4] ?? '').replace(/\\n|\/n|\r\n?/g, '\n'), effect: {
        kind: 'positioned', x: coordinate(values[0], 0), y: coordinate(values[1], 1),
        toX: coordinate(values[7] ?? values[0], 0), toY: coordinate(values[8] ?? values[1], 1),
        lifetime, moveDuration: bounded(Number(values[9] ?? lifetime * 1000) / 1000, lifetime, .001, 60),
        moveDelay: bounded(Number(values[10] ?? 0) / 1000, 0, 0, 60),
        opacity: bounded(opacity[0], 1, 0, 1), endOpacity: bounded(opacity[1] ?? opacity[0], 1, 0, 1),
        rotateZ: bounded(values[5], 0, -360, 360), rotateY: bounded(values[6], 0, -360, 360),
        fontSize: bounded(metadata.fontSize, 25, 10, 100),
        font: shortText(values[12] || 'Microsoft YaHei', 80),
        outline: values[11] !== false && values[11] !== 'false',
        ...(path.length > 1 ? { path } : {}),
      } };
    }
    return { text: '' };
  }
  const payload = object(message);
  const extra = object(metadata.extra);
  const style = { ...object(metadata.style), ...object(metadata.contentStyle), ...object(extra.style),
    ...object(metadata.decoration), ...object(metadata.effect), ...object(payload.style), ...object(payload.effect) };
  const badge = object(style.badge || metadata.badge);
  const theme = String(style.kind || style.type || style.theme || (typeof metadata.effect === 'string' ? metadata.effect : '')).toLowerCase();
  const label = shortText(badge.label || badge.text || style.label || (typeof metadata.badge === 'string' ? metadata.badge : ''));
  const icons = { heart: 'heart', hearts: 'heart', love: 'heart', '爱心': 'heart', star: 'star', sparkle: 'star', '星星': 'star', flower: 'flower', '鲜花': 'flower' };
  const icon = icons[String(style.icon || badge.icon || theme).toLowerCase()];
  const kind = label || ['badge', 'vip', 'medal'].includes(theme) ? 'badge'
    : ['celebrate', 'sparkle', 'star', 'flower'].includes(theme) ? 'celebrate'
    : icon || ['highlight', 'heart', 'hearts', 'bubble'].includes(theme) || style.borderColor || style.backgroundColor ? 'highlight' : '';
  let text = typeof message === 'object' && message !== null || kind && Object.keys(payload).length
    ? payload.text ?? payload.content ?? payload.message ?? '' : message;
  const repeat = Math.floor(bounded(metadata.repeatCount ?? style.repeatCount, 1, 1, 9999));
  if (repeat > 1) text = `${text} ×${repeat}`;
  if (!kind) return { text };
  return { text, effect: {
    kind, label, icon: icon || (kind === 'badge' ? 'star' : 'heart'),
    foreground: rgb(style.color ?? style.textColor, 0xffffff),
    background: rgb(style.backgroundColor ?? style.background, kind === 'badge' ? 0x201b10 : 0x301527),
    border: rgb(style.borderColor ?? style.border, kind === 'badge' || kind === 'celebrate' ? 0xe8bc58 : 0xe962ab),
  } };
}
