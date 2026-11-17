import { randomBytes } from 'node:crypto';
import { fetchResponse } from './http.mjs';
import { normalizeHeaders } from './playback.mjs';
import { fetchScopedMedia, scopedMediaHeaders } from './media-cache.mjs';

const httpURL = value => /^https?:\/\//i.test(value);
const xmlEscape = value => String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[character]));
function xmlValue(value) {
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (_match, name) => {
    if (name[0] === '#') {
      const number = name[1].toLowerCase() === 'x' ? parseInt(name.slice(2), 16) : Number(name.slice(1));
      if (!Number.isSafeInteger(number) || number <= 0 || number > 0x10ffff || number >= 0xd800 && number <= 0xdfff) throw new Error('Invalid XML entity');
      return String.fromCodePoint(number);
    }
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[name.toLowerCase()];
  });
}

// A small token-preserving XML reader: untouched timing/codec/DRM metadata is
// emitted byte-for-byte. DTDs, entities and external XML include branches are
// unsupported and therefore return to the source's native DASH demuxer.
function parseXML(source) {
  if (/<!DOCTYPE|<!ENTITY|<!\[CDATA\[|\bxlink:|\bxml:base/i.test(source)) throw new Error('Unsupported MPD XML');
  const document = { name: '', children: [], start: 0, end: source.length }, stack = [document];
  const tokens = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<\/?[A-Za-z_][^<>]*>/g;
  let token, nodes = 0;
  while ((token = tokens.exec(source))) {
    const raw = token[0];
    if (raw.startsWith('<!--') || raw.startsWith('<?')) continue;
    const closing = /^<\//.test(raw), match = /^<\/?([A-Za-z_][\w:.-]*)/.exec(raw);
    if (!match) throw new Error('Invalid XML');
    const name = match[1], localName = name.split(':').at(-1);
    if (closing) {
      const node = stack.pop();
      if (!node || node === document || node.name !== name || !/^<\/[\w:.-]+\s*>$/.test(raw)) throw new Error('Mismatched XML');
      node.closeStart = token.index; node.end = tokens.lastIndex;
      continue;
    }
    if (++nodes > 30000 || stack.length > 64) throw new Error('MPD XML exceeds node limit');
    const node = { name, localName, raw, start: token.index, openEnd: tokens.lastIndex, children: [], attributes: new Map() };
    const attributes = /([\w:.-]+)\s*=\s*(["'])([\s\S]*?)\2/g;
    attributes.lastIndex = match[0].length;
    let field;
    while ((field = attributes.exec(raw))) {
      if (node.attributes.has(field[1])) throw new Error('Duplicate XML attribute');
      const valueStart = token.index + field.index + field[0].indexOf(field[2]) + 1;
      node.attributes.set(field[1], { value: xmlValue(field[3]), start: valueStart, end: valueStart + field[3].length });
    }
    stack.at(-1).children.push(node);
    if (/\/\s*>$/.test(raw)) { node.closeStart = node.openEnd; node.end = node.openEnd; }
    else stack.push(node);
  }
  if (stack.length !== 1 || document.children.length !== 1 || document.children[0].localName !== 'MPD') throw new Error('Invalid MPD');
  const root = document.children[0];
  if (root.attributes.get('type')?.value === 'dynamic') throw new Error('Live DASH is not cached');
  return root;
}

function resolveTemplate(value, base) {
  const slots = [];
  const safe = value.replace(/\$\$|\$(?:RepresentationID|Number|Bandwidth|Time)(?:%0\d+d)?\$/g, slot => {
    const marker = `YINGXIADASHSLOT${slots.length}END`; slots.push([marker, slot]); return marker;
  });
  let result = new URL(safe, base).href;
  for (const [marker, slot] of slots) result = result.replaceAll(marker, slot);
  return result;
}

export class DashCache {
  constructor({ baseURL, cache, maxPlaylistBytes = 8 * 1024 ** 2, maxRoutes = 50000 } = {}) {
    this.baseURL = typeof baseURL === 'function' ? baseURL : () => baseURL;
    Object.assign(this, { cache, maxPlaylistBytes, maxRoutes }); this.contexts = new Map();
  }
  prepare(id, address, headers, owner) {
    const token = randomBytes(24).toString('hex');
    const context = { id, token, address, headers: normalizeHeaders(headers), owner, routes: new Map(), routeKeys: new Map(), snapshot: null, fallback: false };
    this.contexts.set(token, context);
    return `${this.baseURL()}/dash-cache/${token}/index.mpd`;
  }
  register(context, address, mode = 'fixed') {
    if (!httpURL(address)) throw new Error('Non-HTTP MPD dependency');
    const key = `${mode}:${address}`;
    let route = context.routeKeys.get(key);
    if (!route) {
      if (context.routes.size >= this.maxRoutes) throw new Error('MPD dependencies exceed limit');
      const token = randomBytes(16).toString('hex');
      const parsed = new URL(address);
      if (parsed.username || parsed.password) throw new Error('Unsupported MPD credentials');
      const headers = scopedMediaHeaders(context.effectiveHeaders || context.headers, context.effectiveURL || context.address, address);
      route = { token, address, mode, headers, origin: parsed.origin, templatePath: parsed.pathname, templateQuery: parsed.search,
        prefix: mode === 'base' ? new URL('.', parsed).href : '' };
      context.routes.set(token, route); context.routeKeys.set(key, route);
    }
    const source = new URL(address);
    const query = source.search;
    const pathname = source.pathname;
    return `${this.baseURL()}/dash-cache/${context.token}/${route.token}${pathname}${query}`;
  }
  rewrite(context, source, sourceURL) {
    const root = parseXML(source), edits = [];
    const remove = node => edits.push({ start: node.start, end: node.end, value: '' });
    const text = (node, value) => edits.push({ start: node.openEnd, end: node.closeStart, value: xmlEscape(value) });
    const childXML = (node, base) => {
      const replacements = [];
      const visit = child => {
        for (const name of ['sourceURL', 'media', 'index']) {
          const field = child.attributes.get(name); if (!field) continue;
          replacements.push({ start: field.start - node.start, end: field.end - node.start,
            value: xmlEscape(this.register(context, resolveTemplate(field.value, base), 'fixed')) });
        }
        for (const nested of child.children) visit(nested);
      };
      visit(node);
      let result = source.slice(node.start, node.end);
      for (const replacement of replacements.sort((left, right) => right.start - left.start))
        result = result.slice(0, replacement.start) + replacement.value + result.slice(replacement.end);
      return result;
    };
    const descriptorXML = (chain, base) => {
      const attributes = new Map(), children = new Map();
      for (const node of chain) {
        for (const [name, field] of node.attributes) attributes.set(name, field.value);
        const groups = new Map();
        for (const child of node.children) {
          if (!groups.has(child.localName)) groups.set(child.localName, []);
          groups.get(child.localName).push(child);
        }
        for (const [name, nodes] of groups) children.set(name, nodes);
      }
      const node = chain.at(-1), fields = [...attributes].map(([name, value]) => {
        if (node.localName === 'SegmentTemplate' && ['media', 'initialization', 'index'].includes(name))
          value = this.register(context, resolveTemplate(value, base), 'template');
        return ` ${name}="${xmlEscape(value)}"`;
      }).join('');
      const nested = [...children.values()].flat().map(child => childXML(child, base)).join('');
      return nested ? `<${node.name}${fields}>${nested}</${node.name}>` : `<${node.name}${fields}/>`;
    };
    const addressing = new Set(['SegmentTemplate', 'SegmentList', 'SegmentBase']);
    const visit = (node, inheritedBase, inheritedDescriptor = []) => {
      if (['Location', 'PatchLocation'].includes(node.localName)) { remove(node); return; }
      const bases = node.children.filter(child => child.localName === 'BaseURL');
      if (bases.length > 1) throw new Error('Alternative DASH BaseURL origins require native resolution');
      let base = inheritedBase;
      if (bases.length) {
        const child = bases[0];
        if (child.children.length || child.closeStart === child.openEnd) throw new Error('Invalid DASH BaseURL');
        const value = xmlValue(source.slice(child.openEnd, child.closeStart).trim());
        base = resolveTemplate(value, inheritedBase);
        if (!httpURL(base)) throw new Error('Non-HTTP DASH BaseURL');
        text(child, this.register(context, base, 'base'));
      }
      const descriptors = node.children.filter(child => addressing.has(child.localName));
      if (descriptors.length > 1) throw new Error('Ambiguous DASH segment addressing');
      const local = descriptors[0];
      const descriptor = local ? [...(inheritedDescriptor.at(-1)?.localName === local.localName ? inheritedDescriptor : []), local] : inheritedDescriptor;
      if (node.localName === 'Representation' && descriptor.length) {
        const specialized = descriptorXML(descriptor, base);
        if (local) edits.push({ start: local.start, end: local.end, value: specialized });
        else if (node.closeStart === node.openEnd) {
          const opening = node.raw.replace(/\/\s*>$/, '>');
          edits.push({ start: node.start, end: node.end, value: opening + specialized + `</${node.name}>` });
        } else edits.push({ start: node.closeStart, end: node.closeStart, value: specialized });
      } else if (local) remove(local);
      for (const child of node.children) if (child.localName !== 'BaseURL' && !addressing.has(child.localName)) visit(child, base, descriptor);
    };
    visit(root, sourceURL);
    edits.sort((left, right) => right.start - left.start);
    let result = source;
    for (const edit of edits) result = result.slice(0, edit.start) + edit.value + result.slice(edit.end);
    return result;
  }
  markPreview(source) {
    // Mark every capability URI in both elements and attributes. XML escaping
    // is reapplied so a source's signed ampersands remain legal XML.
    const prefix = this.baseURL() + '/dash-cache/';
    return source.replace(/(?:https?:\/\/)[^\s<"']+/g, address => {
      const raw = xmlValue(address);
      if (!raw.startsWith(prefix)) return address;
      return xmlEscape(raw + (raw.includes('?') ? '&' : '?') + 'cacheOnly=1');
    });
  }
  async snapshot(context, signal) {
    if (context.loading) return context.loading;
    context.loading = (async () => {
      let remote;
      try {
        remote = await fetchScopedMedia(context.address, { headers: context.headers, signal,
          timeoutMs: 15000, method: 'GET', allowInsecureRedirect: true });
        const chunks = []; let size = 0;
        if (!remote.response.ok) throw new Error('MPD fetch rejected');
        for await (const chunk of remote.response.body || []) {
          size += chunk.length; context.owner.networkBytes = (context.owner.networkBytes || 0) + chunk.length;
          if (size > this.maxPlaylistBytes) throw new Error('MPD exceeds size limit');
          signal.throwIfAborted(); chunks.push(Buffer.from(chunk));
        }
        const original = Buffer.concat(chunks).toString('utf8');
        context.effectiveHeaders = remote.scopedHeaders || remote.headers;
        context.effectiveURL = remote.url;
        const manifest = this.rewrite(context, original, remote.url);
        context.snapshot = { manifest, preview: this.markPreview(manifest) };
        return context.snapshot;
      } catch (error) {
        signal.throwIfAborted();
        context.fallback = true; context.owner.nativeFallback = true; context.routes.clear(); context.routeKeys.clear(); return null;
      } finally { remote?.release(); await remote?.response.body?.cancel().catch(() => {}); }
    })().finally(() => { context.loading = null; });
    return context.loading;
  }
  sourceAddress(route, pathname, query) {
    const candidate = route.origin + pathname + query;
    if (route.mode === 'base') {
      if (candidate === route.address) return candidate;
      if (!new URL(candidate).href.startsWith(route.prefix)) return null;
      return candidate;
    }
    const pattern = value => '^' + value.split(/(\$\$|\$(?:RepresentationID|Number|Bandwidth|Time)(?:%0\d+d)?\$)/).map(part => {
      if (part === '$$') return '\\$';
      if (/^\$(?:Number|Bandwidth|Time)/.test(part)) return '\\d+';
      if (part === '$RepresentationID$') return '[^/&?]+';
      return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }).join('') + '$';
    if (!new RegExp(pattern(route.templatePath)).test(pathname) || !new RegExp(pattern(route.templateQuery)).test(query)) return null;
    return candidate;
  }
  async handle(request, response, url) {
    if (!url.pathname.startsWith('/dash-cache/')) return false;
    const match = /^\/dash-cache\/([a-f\d]{48})\/(.*)$/.exec(url.pathname);
    const context = match && this.contexts.get(match[1]);
    if (!context || context.owner.closed || !['GET', 'HEAD'].includes(request.method)) { response.writeHead(404).end(); return true; }
    const preview = url.searchParams.get('cacheOnly') === '1';
    if (match[2] === 'index.mpd') {
      const disconnected = new AbortController();
      const onClose = () => { if (!response.writableEnded) disconnected.abort(); }; response.once('close', onClose);
      const signal = AbortSignal.any([context.owner.controller.signal, disconnected.signal]);
      try {
        if (preview && (!context.owner.enabled || !context.snapshot)) { response.writeHead(504).end(); return true; }
        const snapshot = context.snapshot || (!context.fallback ? await this.snapshot(context, signal) : null);
        if (!snapshot) { response.writeHead(preview ? 504 : 307, preview ? {} : { Location: context.address, 'Cache-Control': 'no-store' }).end(); return true; }
        const manifest = preview ? snapshot.preview : snapshot.manifest;
        response.writeHead(200, { 'Content-Type': 'application/dash+xml', 'Content-Length': Buffer.byteLength(manifest), 'Cache-Control': 'no-store' });
        response.end(request.method === 'HEAD' ? undefined : manifest);
      } catch { if (response.headersSent || signal.aborted) response.destroy(); else response.writeHead(502).end(); }
      finally { response.removeListener('close', onClose); }
      return true;
    }
    const child = /^([a-f\d]{32})(\/.*)$/.exec(match[2]);
    const route = child && context.routes.get(child[1]);
    if (!route) { response.writeHead(404).end(); return true; }
    // Strip only the preview flag appended by our own rewritten manifest.
    // Original signed query bytes are otherwise retained exactly as supplied.
    const query = preview ? url.search.replace(/([?&])cacheOnly=1(?=&|$)/g, (_whole, delimiter) => delimiter === '?' ? '?' : '').replace(/\?&/, '?').replace(/\?$/, '') : url.search;
    const address = this.sourceAddress(route, child[2], query);
    if (!address) { response.writeHead(404).end(); return true; }
    const resource = this.cache.resource(context.owner, address, route.headers);
    resource.scopedCredentials = true;
    if (preview) await this.cache.preview(resource, request, response);
    else await this.cache.transfer(context.owner, resource, {}, request, response);
    return true;
  }
  release(id) { for (const [token, context] of this.contexts) if (context.id === id) this.contexts.delete(token); }
  clear() { for (const context of this.contexts.values()) { context.snapshot = null; context.fallback = false; } }
  close() { this.contexts.clear(); }
}
