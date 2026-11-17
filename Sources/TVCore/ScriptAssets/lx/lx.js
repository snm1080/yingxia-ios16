// LX Music custom sources (洛雪音乐自定义源) on the TVBox prelude: the `lx` object of LX Music
// desktop's user API (src/main/modules/userApi/renderer/preload.js, API version 2.0.0), for the
// musicUrl and lyric actions. MusicLXSources.swift keeps each imported script's state.
const host = globalThis.__host;
const EVENT_NAMES = Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' });
const sourceKeys = ['kw', 'kg', 'tx', 'wy', 'mg'];
// MusicLXSources gives a whole lookup 8 seconds.
const requestLimit = 8000;
const pendingRequests = new Set();
let activeRequests = null;

let requestHandler = null;
let inited = null;
let initedResolve;
const initedPromise = new Promise(resolve => { initedResolve = resolve; });

const toBuffer = value => value instanceof Uint8Array ? Buffer.from(value) : Buffer.from(String(value ?? ''), 'utf8');
const crypto = request => JSON.parse(host('crypto', JSON.stringify(request)));
const formBody = data => typeof data === 'string' ? data : new URLSearchParams(data).toString();

function send(eventName, data) {
    return new Promise((resolve, reject) => {
        if (eventName === EVENT_NAMES.inited) {
            if (inited) return reject(new Error('Script is inited'));
            inited = data || {};
            initedResolve();
            return resolve();
        }
        // Update notices from the script's author are not shown.
        if (eventName === EVENT_NAMES.updateAlert) return resolve();
        reject(new Error('The event is not supported: ' + eventName));
    });
}

function on(eventName, handler) {
    if (eventName !== EVENT_NAMES.request) return Promise.reject(new Error('The event is not supported: ' + eventName));
    requestHandler = handler;
    return Promise.resolve();
}

/// needle's behaviour as LX uses it: the answer's body is parsed as JSON when it is JSON.
function request(url, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    const { method = 'get', timeout, headers = {}, body, form, formData } = options || {};
    let cancelled = false, nativeID = null, pollTimer = null;
    const owner = activeRequests;
    const remove = () => { pendingRequests.delete(cancel); owner?.delete(cancel); };
    const cancel = () => {
        if (cancelled) return;
        cancelled = true;
        if (pollTimer != null) clearTimeout(pollTimer);
        if (nativeID != null) { try { host('httpCancel', nativeID); } catch {} }
        remove();
    };
    pendingRequests.add(cancel); owner?.add(cancel);
    Promise.resolve().then(() => {
        if (cancelled) return;
        const fields = {};
        for (const [key, value] of Object.entries(headers || {})) if (value != null) fields[key] = String(value);
        const has = name => Object.keys(fields).some(key => key.toLowerCase() === name);
        let payload = null;
        if (body != null) {
            if (typeof body === 'string' || body instanceof Uint8Array) payload = body;
            else if (has('content-type') && /json/i.test(Object.entries(fields).find(([key]) => key.toLowerCase() === 'content-type')[1])) payload = JSON.stringify(body);
            else { payload = formBody(body); if (!has('content-type')) fields['Content-Type'] = 'application/x-www-form-urlencoded'; }
        } else if (form != null || formData != null) {
            payload = formBody(form ?? formData);
            if (!has('content-type')) fields['Content-Type'] = 'application/x-www-form-urlencoded';
        }
        const wait = typeof timeout === 'number' && timeout > 0 ? Math.min(timeout, requestLimit) : requestLimit;
        const binary = payload instanceof Uint8Array;
        // Started natively and polled from a timer, so a script's parallel requests run in parallel and the
        // lookup's deadline still applies while it waits.
        let id;
        try {
            id = host('httpStart', JSON.stringify({
                url: String(url), method: String(method).toUpperCase(), headers: fields, timeout: wait,
                body: payload == null || binary ? null : String(payload), bodyBase64: binary ? Buffer.from(payload).toString('base64') : null,
                binary: true
            }));
            nativeID = id;
        } catch (error) { deliver({ failed: String(error?.message || error) }); return; }
        const poll = () => {
            if (cancelled) return;
            const text = host('httpPoll', id);
            if (text == null) { pollTimer = setTimeout(poll, 10); return; }
            try { deliver(JSON.parse(text)); } catch (error) { deliver({failed: String(error?.message || error)}); }
        };
        pollTimer = setTimeout(poll, 0);
    }).catch(error => deliver({failed: String(error?.message || error)}));
    const deliver = answer => {
        if (cancelled) return;
        nativeID = null; remove();
        if (answer.failed) { try { callback?.call(this, new Error(answer.failed), null, null); } catch {} return; }
        const raw = Buffer.from(answer.base64 || '', 'base64');
        let parsed = raw.toString('utf8');
        try { parsed = JSON.parse(parsed); } catch {}
        try { callback?.call(this, null, { statusCode: answer.code, statusMessage: '', headers: answer.headers || {}, bytes: raw.length, raw, body: parsed }, parsed); } catch {}
    };
    cancel.abort = cancel;
    return cancel;
}

async function invoke(input, action) {
    if (!requestHandler) throw new Error('The source registered no request handler');
    if (!inited?.sources?.[input.source]?.actions?.includes(action)) throw new Error('The source does not declare this action');
    const owned = new Set(), previous = activeRequests;
    activeRequests = owned;
    let timer;
    const milliseconds = Math.min(7500, Math.max(100, Number(input.timeout) || 7000));
    try {
        return await Promise.race([
            Promise.resolve().then(() => requestHandler({source: input.source, action, info: {type: input.quality, musicInfo: input.musicInfo}})),
            new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('request timeout')), milliseconds); })
        ]);
    } finally {
        clearTimeout(timer);
        for (const cancel of owned) cancel();
        activeRequests = previous;
    }
}

const utils = {
    crypto: {
        aesEncrypt(buffer, mode, key, iv) {
            const ecb = /ecb/i.test(String(mode));
            const answer = crypto({ op: 'aes', encrypt: true, mode: ecb ? 'ECB' : 'CBC', padding: true,
                data: toBuffer(buffer).toString('base64'), key: toBuffer(key).toString('base64'), iv: ecb ? '' : toBuffer(iv).toString('base64') });
            return Buffer.from(answer.data, 'base64');
        },
        rsaEncrypt(buffer, key) {
            const answer = crypto({ op: 'rsaRaw', key: String(key), data: toBuffer(buffer).toString('base64') });
            return Buffer.from(answer.data, 'base64');
        },
        randomBytes(size) { return Buffer.from(crypto({ op: 'random', count: Number(size) }).data, 'base64'); },
        md5(value) {
            if (typeof value === 'string') return host('md5', value);
            return crypto({ op: 'hash', alg: 'md5', data: toBuffer(value).toString('base64') }).hex;
        }
    },
    buffer: {
        from(...args) { return Buffer.from(...args); },
        bufToString(buf, format) { return (typeof buf === 'string' ? Buffer.from(buf, 'binary') : toBuffer(buf)).toString(format); }
    },
    zlib: {
        inflate(buf) {
            return new Promise(resolve => resolve(Buffer.from(crypto({ op: 'inflate', data: toBuffer(buf).toString('base64'), output: 'base64' }).data, 'base64')));
        },
        deflate(data) { return new Promise(resolve => resolve(Buffer.from(globalThis.pako.deflate(toBuffer(data))))); }
    }
};

const info = JSON.parse(host('module', 'lx://info'));
const rawScript = host('module', 'lx://script');
const silent = () => {};
// Scripts print their requests, keys included; none of it reaches the app's logs. Every console method
// (group, groupEnd, table, time...) exists, as in a browser.
globalThis.console = new Proxy({}, { get: () => silent });
globalThis.lx = Object.freeze({
    EVENT_NAMES, request, send, on, utils, version: '2.0.0', env: 'desktop',
    currentScriptInfo: Object.freeze({ ...info, rawScript })
});

globalThis.__lx = {
    /// Runs the script as LX does (a classic script, not a module) and waits for its inited event.
    /// Answers {sources: {tx: ['128k', ...], ...}} with the sources that resolve music URLs.
    async load() {
        try {
            (0, eval)(rawScript);
            await initedPromise;
            if (inited.status === false) return { error: 'The source reported initialization failure' };
            const sources = {}, actions = {};
            for (const key of sourceKeys) {
                const entry = inited.sources?.[key];
                if (!entry || entry.type !== 'music' || !Array.isArray(entry.actions)) continue;
                actions[key] = [...new Set(entry.actions.filter(action => ['musicUrl', 'lyric', 'pic'].includes(action)))];
                if (actions[key].includes('musicUrl')) {
                    sources[key] = [...new Set((Array.isArray(entry.qualitys) ? entry.qualitys : []).filter(quality => typeof quality === 'string' && /^[A-Za-z0-9_+-]{1,32}$/.test(quality)))].slice(0, 32);
                }
            }
            if (!requestHandler) return { error: 'The source registered no request handler' };
            return { sources, actions };
        } catch (error) { return { error: String(error?.message || error) }; }
    },
    /// One musicUrl request: {source, quality, musicInfo}. Answers {url} or {error}.
    async musicUrl(input) {
        try {
            const answer = await invoke(input, 'musicUrl');
            const url = typeof answer === 'string' ? answer : answer?.url;
            if (typeof url !== 'string' || url.length > 16384 || !/^https?:\/\//i.test(url)) throw new Error('The source returned no address');
            const headers = {};
            for (const [name, value] of Object.entries(answer?.headers || {}).slice(0, 64)) {
                if (typeof value === 'string' && /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) && !/[\r\n]/.test(value)) headers[name] = value;
            }
            return { url, headers };
        } catch (error) { return { error: String(error?.message || error).slice(0, 300) }; }
    },
    async lyric(input) {
        try {
            const lyric = await invoke(input, 'lyric');
            const encoded = JSON.stringify(lyric);
            if (!encoded || encoded.length > 2000000 || lyric == null) throw new Error('The source returned no lyrics');
            return {lyric};
        } catch (error) { return { error: String(error?.message || error).slice(0, 300) }; }
    },
    cancelAll() {
        for (const cancel of pendingRequests) cancel();
        return true;
    }
};
