export class AppError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.status = status;
  }
}

export function publicLocation(raw) {
  try {
    const url = new URL(String(raw));
    if (!['http:', 'https:'].includes(url.protocol)) return String(raw);
    return `${url.origin}${url.pathname}${url.search ? '?…' : ''}`;
  } catch {
    return String(raw ?? '');
  }
}

export function redact(value) {
  return String(value ?? '')
    .replace(/https?:\/\/[^\s<>"']+/gi, (url) => publicLocation(url))
    .replace(/\b(Basic|Bearer)\s+[A-Za-z0-9+/_.=\-]+/gi, '$1 [已隐藏]')
    .replace(
      /(["']?(?:password|passwd|cookie|authorization|access[_-]?token|refresh[_-]?token|token|secret)["']?\s*[=:]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+)/gi,
      '$1"[已隐藏]"',
    );
}

export function publicError(error) {
  return {
    code: error instanceof AppError ? error.code : 'INTERNAL_ERROR',
    message: redact(error?.message || '操作失败，请重试'),
  };
}

export function requireText(value, label, max = 8192) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) {
    throw new AppError('INVALID_ARGUMENT', `${label}无效`);
  }
  return value.trim();
}
