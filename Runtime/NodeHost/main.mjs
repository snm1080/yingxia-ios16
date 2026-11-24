// CatPawOpen bundles run in independent workers; the authenticated loopback
// control server and portable mobile services remain in the app host isolate.
import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { MobileServices } from './mobile-services.mjs';
import { mobileFetch } from './mobile-fetch.mjs';
import { pushPlayBody, pushSupportResult, sourcePushPlayback } from './push-playback.mjs';
import { BundleWorker } from './bundle-worker.mjs';
import { BundlePool } from './bundle-pool.mjs';
import { SourceFence } from './source-fence.mjs';
import { setProxy } from './agents.mjs';
import { request } from './http-request.mjs';
import { installDiagnostics, log, thrownText } from './diagnostics.mjs';

globalThis.fetch = mobileFetch;
installDiagnostics();
const [controlFile, relistenFile] = process.argv.slice(2);
const token = crypto.randomBytes(16).toString('hex');
const sourceFence = new SourceFence();
const mediaServices = new MobileServices(path.join(path.dirname(controlFile), 'MediaServices'), () => `http://127.0.0.1:${control.address()?.port || 0}`);

// Bundles ask the app for things by POSTing {action, opt} to http://127.0.0.1:<catDartServerPort()>/msg, as the CatVod
// Open apps take them. The host's `messages` server answers that address (`answerMessage`). The one request kept is a
// page to open: a config center entry asks for its page that way ("openInternalWebview") and may say nothing else
// about it (#315). Keep in step with host.mjs.
// The 豆儿 and Lmentor bundles ask for their own page at the device's network address, as a phone would scan it
// (http://192.168.1.5:<port>/website, #385): it counts once it is on the bundle's server (`loopbackPage`).
async function answerMessage(req, res, context) {
    const { pageWatchers } = context;
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let message = {};
    try { message = JSON.parse(Buffer.concat(chunks).toString('utf8')) || {}; } catch { }
    const page = String(message.opt?.url || '');
    const owner = req.headers?.['x-wincat-play-session'];
    const pending = owner && context.pendingDanmaku.get(owner);
    const target = pending || context, { catPlaying } = target;
    const ownsPlayback = !!pending || !catPlaying.owner || (owner === catPlaying.owner &&
        activeDanmakuOwner.owner === owner && activeDanmakuOwner.generation === catPlaying.generation);
    if (['getPlayInfo', 'danmuPush'].includes(message.action) && !ownsPlayback) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ ok: false }));
        return;
    }
    if (message.action === 'getPlayInfo') {
        catPlaying.asked = Date.now();
        const { title, episodeName, flag } = catPlaying;
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ title, episodeName, flag }));
        return;
    }
    if (message.action === 'danmuPush' && loopbackPage(page) && pushedDanmakuMatches(page, catPlaying))
        target.catPushed = { url: page.replace('//localhost:', '//127.0.0.1:'), at: Date.now() };
    if (['openInternalWebview', 'openWeb'].includes(message.action) && /^http:\/\/(127\.0\.0\.1|localhost|\d+\.\d+\.\d+\.\d+):\d+(\/|$)/.test(page)) {
        for (const watch of pageWatchers) watch(page);
    }
    // Anything else gets nothing back, as when no one answered: the bundle carries on without it.
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('null');
}
// The page on loopback, as the app opens it, or undefined when it is served anywhere else.
const loopbackPage = page => page && /^http:\/\/(127\.0\.0\.1|localhost):\d+(\/|$)/.test(page) ? page : undefined;
const isMessage = req => req.method === 'POST' && req.url === '/msg';

// CatPawOpen bundles find danmaku for what plays, as the CatVod Open apps take it (#506): a moment after a play the
// 9280.kstore.vip bundle asks the app what plays ("getPlayInfo": {title, episodeName, flag}), matches that in its own
// danmu_api and sends the comments' address back ("danmuPush": http://127.0.0.1:<port>/danmu/auto?name=…&episode=…).
// The host names each play from the detail answers it passed on; the app asks for the address with `catDanmaku` and
// fetches the comments itself. A bundle that never asks gets no answer it didn't get before. Keep in step with host.mjs.
function sourceContext() {
    return { pageWatchers: new Set(), catTitles: new Map(), pendingDanmaku: new Map(),
        catPlaying: { title: '', episodeName: '', flag: '', at: 0, asked: 0 }, catPushed: { url: '', at: 0 } };
}
// One monotonic app generation covers playback and subscription changes. A late
// request may never reactivate an older A after playback has moved A → B → A.
let activeDanmakuOwner = { generation: 0, owner: '' };
function bindDanmaku(context, params) {
    if (!params.catDanmakuOwner || params.catDanmakuPending === '1') return;
    const generation = Number(params.catDanmakuGeneration), owner = String(params.catDanmakuOwner);
    if (!Number.isSafeInteger(generation) || generation < 1 || generation < activeDanmakuOwner.generation ||
        (generation === activeDanmakuOwner.generation && owner !== activeDanmakuOwner.owner))
        throw new Error('The danmaku playback session has changed');
    activeDanmakuOwner = { generation, owner };
    if (context.catPlaying.owner === owner && context.catPlaying.generation === generation) return;
    const pending = context.pendingDanmaku.get(owner);
    context.pendingDanmaku.delete(owner);
    context.catPushed = pending?.catPushed || { url: '', at: 0 };
    context.catPlaying = { title: String(params.danmakuTitle || ''), episodeName: String(params.danmakuEpisode || ''),
        flag: String(params.danmakuFlag || ''), at: pending?.catPlaying.at || Date.now(),
        asked: pending?.catPlaying.asked || 0, owner, generation };
}
function rememberTitles(context, text) {
    const { catTitles } = context;
    let list;
    try { list = JSON.parse(text)?.list; } catch { return; }
    for (const video of Array.isArray(list) ? list : []) {
        const title = String(video?.vod_name ?? '').trim();
        if (!title) continue;
        const flags = String(video.vod_play_from ?? '').split('$$$');
        String(video.vod_play_url ?? '').split('$$$').forEach((line, index) => {
            for (const item of line.split('#')) {
                const cut = item.indexOf('$');
                const episodeName = cut < 0 ? '' : item.slice(0, cut).trim(), id = cut < 0 ? item : item.slice(cut + 1);
                if (!id.trim()) continue;
                catTitles.delete(id);
                catTitles.set(id, { title, episodeName, flag: flags[index] || '' });
            }
        });
    }
    while (catTitles.size > 3000) catTitles.delete(catTitles.keys().next().value);
}
function startedPlaying(context, flag, id, params = {}) {
    if (params.catPlayback === 'false') return;
    const known = context.catTitles.get(id);
    const title = String(params.danmakuTitle || known?.title || '').trim();
    const episodeName = String(params.danmakuEpisode || known?.episodeName || '').trim();
    const playing = { title, episodeName, flag: flag || known?.flag || '', at: Date.now(), asked: 0 };
    if (params.catDanmakuPending === '1' && params.catDanmakuOwner) {
        // Resolving/prefetching is not activation. Its delayed callbacks remain
        // attached to this exact prepared choice until the native player adopts it.
        context.pendingDanmaku.set(params.catDanmakuOwner, { catPlaying: playing, catPushed: { url: '', at: 0 } });
        while (context.pendingDanmaku.size > 64) context.pendingDanmaku.delete(context.pendingDanmaku.keys().next().value);
    } else {
        context.catPushed = { url: '', at: 0 };
        context.catPlaying = playing;
    }
}
// The subscribed automatic endpoints carry enough identity to reject a late
// previous episode after a rapid switch. Opaque feeds carry no such proof and
// remain supported; do not infer their episode from an arbitrary URL path.
function pushedDanmakuMatches(page, playing) {
    let url;
    try { url = new URL(page); } catch { return false; }
    if (!['/danmu/auto', '/danmu-proxy'].includes(url.pathname.replace(/\/+$/, ''))) return true;
    const name = url.searchParams.get('name');
    if (name && playing.title && name.trim() !== playing.title.trim()) return false;
    const episode = url.searchParams.get('episode') || url.searchParams.get('episodeNumber');
    if (!episode || !playing.episodeName || episode.trim() === playing.episodeName.trim()) return true;
    const number = value => {
        const plain = value.trim().match(/^(?:第\s*)?(\d{1,4})\s*(?:[集话話回]|$)/i)
            || value.match(/(?:^|[^a-z\d])S\d{1,3}[ ._-]*E(?:P)?[ ._-]*(\d{1,4})(?!\d)/i)
            || value.trim().match(/^ep(?:isode)?[ ._-]*(\d{1,4})(?:\D|$)/i);
        return plain ? Number(plain[1]) : undefined;
    };
    const requested = number(episode), current = number(playing.episodeName);
    return requested === undefined || current === undefined || requested === current;
}
// The comments' address for an episode: the one the bundle sent for this play, or else its /danmu/auto for the name
// the app asks with (a bundle without it answers 404). `pending` while the bundle may still send one: it asks what
// plays 800 ms after the play and sends the address straight after the answer.
function danmakuAddress(context, port, params) {
    const { catPlaying, catPushed } = context;
    const now = Date.now(), name = String(params.name || ''), episode = String(params.episode || '');
    const current = catPlaying.title === name && catPlaying.episodeName === episode;
    const pushed = current && catPushed.at >= catPlaying.at && catPushed.url.startsWith(`http://127.0.0.1:${port}/`) ? catPushed.url : '';
    const pending = current && !pushed && now - catPlaying.at < 3000 && !(catPlaying.asked && now - catPlaying.asked > 500);
    const query = new URLSearchParams({ name });
    if (episode) query.set('episode', episode);
    return { result: JSON.stringify({ url: pushed || `http://127.0.0.1:${port}/danmu/auto?${query}`, pushed: !!pushed, pending }) };
}
// Messages go to a server of the host's own: a bundle that finds its own port behind catDartServerPort() skips the call
// as a call to itself (BRIDGE_SELF_CALL in the 豆儿 and Lmentor bundles), so pages they ask for never arrived (#385).
// A bridge for each bundle also keeps delayed config pages and danmaku messages
// attached to their source when requests from two bundles overlap.
function createMessages(context) {
    const messages = http.createServer((req, res) => {
        if (isMessage(req)) return answerMessage(req, res, context).catch(error => {
            log('CATPAW_MESSAGES', thrownText(error));
            if (!res.headersSent) res.writeHead(500);
            res.end();
        });
        res.writeHead(404); res.end();
    });
    messages.on('error', error => log('CATPAW_MESSAGES', thrownText(error)));
    return messages;
}
// A detail answer for which the bundle asked to open a page: the page's address joins the video's synopsis, where the
// app finds a config center (CatPawOpen.configCenter). Some bundles answer such an entry with an empty list.
function withPage(text, page) {
    let answer;
    try { answer = JSON.parse(text); } catch { return text; }
    if (!answer || typeof answer !== 'object' || Array.isArray(answer)) return text;
    const list = Array.isArray(answer.list) ? answer.list : [];
    const video = list[0] && typeof list[0] === 'object' ? list[0] : {};
    if (!`${video.vod_content ?? ''}\n${video.vod_remarks ?? ''}`.includes(page)) {
        video.vod_content = [video.vod_content, page].filter(Boolean).join('\n');
    }
    answer.list = [video, ...list.slice(1)];
    return JSON.stringify(answer);
}
// The detail calls collect what pages the bundle asks to open while it answers. The 豆儿 and Lmentor bundles answer a
// config entry with an empty video first and ask for its page a moment later (#385), so an answer with nothing to play
// waits briefly for that; a video's details come back at once.
async function watchingPages(context, route, send) {
    const { pageWatchers } = context;
    if (!route.endsWith('/detail')) return { text: await send() };
    let page, arrived;
    const watch = address => { page = address; arrived?.(); };
    pageWatchers.add(watch);
    try {
        const text = await send();
        if (!page && !playable(text)) await new Promise(resolve => { arrived = resolve; setTimeout(resolve, 300); });
        return { text, page };
    } finally { pageWatchers.delete(watch); }
}
function playable(text) {
    try { return (JSON.parse(text)?.list ?? []).some(video => video?.vod_play_url); } catch { return true; }
}

// Starts take turns to avoid loading two fresh bundles at once on a phone.
// Calls after startup run independently, with a worker-local NODE_PATH and heap.
const bundlePool = new BundlePool({ log });
const bundles = bundlePool.entries; // bundle + profile -> bounded worker entry
const workers = new Set(); // Includes bundles still loading their config/startup.
let proxy = null;
let proxyKey = 'null';
function useProxy(value) {
    proxy = setProxy(value);
    const next = JSON.stringify(proxy);
    if (next === proxyKey) return;
    proxyKey = next;
    for (const entry of bundles.values()) entry.pending.then(instance => {
        if (!instance.closed) updateProxy(instance).catch(error => log('CATPAW_PROXY', thrownText(error)));
    }, () => { });
}
function updateProxy(instance) {
    if (instance.proxyKey === proxyKey) return instance.proxyUpdate ?? Promise.resolve();
    instance.proxyKey = proxyKey;
    const pending = instance.update({ proxy }).catch(async error => {
        await instance.terminate(error);
        throw error;
    }).finally(() => { if (instance.proxyUpdate === pending) instance.proxyUpdate = null; });
    instance.proxyUpdate = pending;
    return pending;
}
async function start(input, evict) {
    const context = sourceContext();
    const messages = createMessages(context);
    let instance;
    try {
        await listen(messages);
        const initialProxyKey = proxyKey;
        instance = new BundleWorker({ bundle: input.bundle, api: input.api, profile: input.profile,
            messagesPort: messages.address().port, proxy }, () => {
            evict();
            workers.delete(instance);
            messages.close();
            messages.closeAllConnections?.();
        });
        Object.assign(instance, { context, messages, proxyKey: initialProxyKey });
        workers.add(instance);
        await instance.ready;
        // A proxy may have changed while this worker loaded its remote config.
        await updateProxy(instance);
        return instance;
    } catch (error) {
        evict();
        messages.close();
        messages.closeAllConnections?.();
        if (instance) await instance.terminate(error);
        throw error;
    }
}
// The app's cloud-drive sign-ins, for bundles that keep their own and sign in through a config center the app can't
// show. Bundles of the wexfnw family take a drive's cookie at PUT /website/api/credential/<drive>/cookie, and the
// Xunlei sign-in (its device and tokens) as their whole Xunlei config. Each sign-in passes on once per change in the
// app, so the bundle's own refreshes of it stay. Keep in step with host.mjs.
const sharedDrives = { quark: 'quarkCookie', uc: 'ucCookie', baidu: 'baiduCookie' };
function sharedSignIns(accounts) {
    const shares = Object.entries(sharedDrives)
        .map(([drive, key]) => ({ drive, route: `/website/api/credential/${drive}/cookie`, value: String(accounts[key] || '').trim() }));
    // A bundle from before Xunlei sign-ins lacks this address; the other drives still pass.
    shares.push({ drive: 'thunder', route: '/website/api/thunder/config', value: accounts.xunlei ? JSON.stringify(accounts.xunlei) : '', optional: true });
    return shares;
}
async function shareAccounts(instance, accountsFile, profile) {
    if (!accountsFile || instance.takesAccounts === false) return;
    let stamp;
    try { stamp = fs.statSync(accountsFile).mtimeMs; } catch { return; }
    if (stamp === instance.accountsStamp) return;
    instance.accountsStamp = stamp;
    const accounts = JSON.parse(fs.readFileSync(accountsFile, 'utf8'));
    const givenFile = `${profile}/yingxia-accounts.json`;
    let given = {};
    try { given = JSON.parse(fs.readFileSync(givenFile, 'utf8')); } catch { }
    const digest = text => crypto.createHash('sha256').update(text).digest('hex');
    let changed = false;
    for (const { drive, route, value, optional } of sharedSignIns(accounts)) {
        if (!value || given[drive] === digest(value)) continue;
        const { status, text } = await request(`http://127.0.0.1:${instance.port}${route}`,
            { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ value }) });
        // The config center answers {code: 0}; anything else is a bundle without one.
        let saved = false;
        try { saved = status >= 200 && status < 300 && JSON.parse(text).code === 0; } catch { }
        if (!saved) { if (optional) continue; instance.takesAccounts = false; break; }
        given[drive] = digest(value); changed = true; log('CATPAW_ACCOUNT', drive);
    }
    if (changed) fs.writeFileSync(givenFile, JSON.stringify(given));
}
// Bundles keep their sites' connections open in their own keep-alive agents (the 9280.kstore.vip bundle's shared axios,
// used by its 秒播 sites), and reuse one the far end has since dropped: a server's idle timeout, or a proxy or NAT
// between. That request fails at once with "socket hang up" and the bundle answers HTTP 500. One more try opens a
// fresh connection. A slow hang-up is a server that drops every request, so it isn't asked twice. Keep in step with
// host.mjs.
async function sendFresh(send, route, body) {
    const started = Date.now();
    try { return await send(route, body); } catch (error) {
        if (error.status !== 500 || !/socket hang up|ECONNRESET|EPIPE/.test(error.message) || Date.now() - started > 2500) throw error;
        log('CATPAW_RETRY', route, error.message);
        return send(route, body);
    }
}
async function call(instance, params, signal, searchOperation) {
    bindDanmaku(instance.context, params);
    if (params.catDanmakuOwner && params.catDanmakuPending !== '1' && instance.danmakuOwner !== params.catDanmakuOwner) {
        instance.danmakuOwner = params.catDanmakuOwner;
        await instance.update({ danmakuOwner: params.catDanmakuOwner });
    }
    const send = async (route, body) => {
        const headers = 'wd' in params ? { 'x-yingxia-search': '1', 'x-yingxia-search-operation': searchOperation } : {};
        if (params.catDanmakuOwner) headers['x-wincat-play-session'] = params.catDanmakuOwner;
        const init = body === undefined ? { headers } : { method: 'POST', headers: { ...headers, 'content-type': 'application/json' }, body: JSON.stringify(body) };
        const ask = () => instance.alive(request(`http://127.0.0.1:${instance.port}${route}`, { ...init,
            maximumBytes: 'wd' in params ? 8 * 1024 * 1024 : Infinity,
            signal: signal ? AbortSignal.any([signal, instance.controller.signal]) : instance.controller.signal }));
        // A refused connection means iOS took the bundle's socket back while the app was suspended.
        const { status, text } = await ask().catch(async error => {
            if (error.code !== 'ECONNREFUSED') throw error;
            if (instance.closed) throw instance.stopped();
            await relistenInstance(instance);
            return ask();
        });
        if (status < 200 || status >= 300) {
            let message = text;
            try { message = JSON.parse(text).message || text; } catch { }
            throw Object.assign(new Error(`The source failed (HTTP ${status}): ${String(message).slice(0, 300)}`), { status });
        }
        return text;
    };
    const ensureDanmakuPort = async address => {
        let url;
        try { url = new URL(address); } catch { return; }
        if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) return;
        const port = Number(url.port || 80);
        if (port === instance.port) return;
        try { await instance.alive(instance.update({ ensureLocalPort: port })); }
        catch (error) { await instance.terminate(error); throw error; }
    };
    if (params.catConfig) return { result: await send('/config') };
    if (params.catWebsite) {
        // Wake/rebind the current bundle before returning the port used by the in-app web view.
        await send('/config');
        return { result: JSON.stringify({ url: `http://127.0.0.1:${instance.port}/website` }) };
    }
    if (params.catDanmakuRoute) {
        const route = params.catDanmakuRoute;
        if (!/^\/(?:website\/danmu\/(?:setting|search|comment)|danmusearch\/api\/(?:search|episodes)|danmuput)$/.test(route)) throw new Error('Invalid danmaku catalog route');
        const values = params.routeParams ? JSON.parse(params.routeParams) : {};
        const query = new URLSearchParams(Object.entries(values).map(([key, value]) => [key, String(value)]));
        const address = route + (query.size ? '?' + query : '');
        if (instance.danmakuAddresses?.has(values.source)) await ensureDanmakuPort(values.source);
        if (route.endsWith('/comment') && params.catDanmakuFeed) {
            // The address is fetched outside /call. Wake the cached source first so returning
            // to a subscription after iOS reclaimed its listener cannot publish its old port.
            await send('/config');
            return { result: JSON.stringify({ url: `http://127.0.0.1:${instance.port}${address}` }) };
        }
        // Aggregate addresses are source identities used by its own allowlist, and may name
        // an independent internal danmaku listener. Only generated host URLs use instance.port.
        const result = await send(address, params.routeBody ? JSON.parse(params.routeBody) : undefined);
        if (route.endsWith('/setting')) {
            try {
                const body = JSON.parse(result), settings = body.data || body;
                instance.danmakuAddresses = new Set((settings.urls || []).filter(entry => entry.builtin === true && entry.enabled !== false)
                    .map(entry => entry.address || entry.url).filter(Boolean));
            } catch { instance.danmakuAddresses = new Set(); }
            for (const value of instance.danmakuAddresses) await ensureDanmakuPort(value);
        }
        return { result };
    }
    // A sign-in the bundle's config center runs with its own QR code (UC's TV token), for accounts the app has no
    // sign-in page for. Keep in step with host.mjs.
    if (params.catLogin) {
        if (!['start', 'poll', 'cancel'].includes(params.catLogin)) throw new Error('Invalid CatPawOpen sign-in');
        instance.loginUntil = params.catLogin === 'cancel' ? 0 : Date.now() + 120_000;
        const result = await send(`/website/api/login/${params.catLogin}`, { provider: params.provider || '', taskId: params.taskId || '' });
        try { if (['success', 'expired'].includes(JSON.parse(result).status)) instance.loginUntil = 0; } catch {}
        return { result };
    }
    if (params.catDanmaku) {
        await send('/config');
        for (const value of instance.danmakuAddresses || []) await ensureDanmakuPort(value);
        return danmakuAddress(instance.context, instance.port, params);
    }
    const api = String(params.catPawOpen || '');
    if (!/^\/spider\/[^?#]+$/.test(api)) throw new Error('Invalid CatPawOpen source');
    // A site without an init route is ready as it is: the xiaosage.361123.xyz bundle's drive sites (玩偶, 花卷, 原盘…)
    // answer its POST with HTTP 404 "站点或接口不存在" and serve everything else (#446). Keep in step with host.mjs.
    if (!instance.started.has(api)) {
        await send(api + '/init', {}).catch(error => { if (error.status !== 404) throw error; });
        instance.started.add(api);
    }
    let route, body;
    if ('pushSupport' in params) { route = '/support'; body = { clip: params.pushSupport, id: params.pushSupport }; }
    else if ('play' in params) { route = '/play'; body = pushPlayBody(params); startedPlaying(instance.context, body.flag, body.id, params); }
    else if ('ids' in params) { route = '/detail'; body = { id: params.ids }; }
    else if ('wd' in params) { route = '/search'; body = { wd: params.wd, page: Number(params.pg || 1), quick: params.quick === 'true' }; }
    else if ('t' in params) { route = '/category'; body = { id: params.t, page: Number(params.pg || 1), filter: true, filters: params.filters ? JSON.parse(params.filters) : {} }; }
    else { route = '/home'; body = {}; }
    // A search that finds nothing answers HTTP 404 in some bundles: the 9280.kstore.vip sites (木偶, 虎斑, 蜡笔…) pass on
    // their site's 404 for a search without matches, and a source without search has no route. Sources whose search
    // returns nothing at all (its 少儿 and 体育 sites) answer 200 with an empty body. None of these is a failure.
    const { text, page } = await watchingPages(instance.context, route, () => (route === '/play'
        ? sourcePushPlayback((route, body) => sendFresh(send, route, body), api, body)
        : sendFresh(send, api + route, body))
        .then(text => route === '/search' && !text.trim() ? '{"list":[]}' : text)
        .catch(error => { if (route === '/search' && error.status === 404) return '{"list":[]}'; throw error; }));
    if (route === '/detail') rememberTitles(instance.context, text);
    if (route === '/support') {
        return { result: JSON.stringify(pushSupportResult(text)) };
    }
    // Sources address the bundle's own proxy by the device's network address, or by a port from before a relisten,
    // but the server is on loopback.
    const ports = instance.ports.join('|');
    const local = address => address.replace(new RegExp(`http://\\d+\\.\\d+\\.\\d+\\.\\d+:(?:${ports})/`, 'g'), `http://127.0.0.1:${instance.port}/`);
    const result = local(text), shown = loopbackPage(page && local(page));
    if (shown) instance.pageUntil = Date.now() + 120_000;
    if (route === '/play') {
        try {
            const url = new URL(JSON.parse(result).url);
            if (['127.0.0.1', 'localhost', '::1', '[::1]'].includes(url.hostname) && instance.ports.includes(Number(url.port)))
                instance.playbackUntil = Date.now() + 120_000;
        } catch {}
    }
    return { result: shown ? withPage(result, shown) : result };
}

// A bundle's media proxy address from before a relisten, at the port that bundle listens on now: a stream that was
// playing when iOS suspended the app asks again there (#485). The address as it is when no bundle had its port.
async function relocate(address) {
    const url = new URL(address);
    // MT registrations live in the host isolate and survive a relisten; only
    // the control port in a minted /mt/ address goes stale, so re-base it.
    if (url.pathname.startsWith('/mt/')) {
        const port = control.address()?.port;
        if (port && Number(url.port) !== port) { url.port = String(port); return url.toString(); }
        return address;
    }
    for (const entry of bundles.values()) {
        const instance = await entry.pending.catch(() => null);
        if (!instance || instance.closed || !instance.ports.includes(Number(url.port))) continue;
        url.port = String(instance.port);
        return url.toString();
    }
    return address;
}

async function sourcePlayback(address, pinned) {
    let url;
    try { url = new URL(address); } catch { return { applied: false, pinned: false }; }
    if (!['http:', 'https:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '::1', '[::1]'].includes(url.hostname)) return { applied: false, pinned: false };
    for (const entry of bundles.values()) {
        const instance = await entry.pending.catch(() => null);
        if (!instance || instance.closed || !instance.ports.includes(Number(url.port))) continue;
        const identity = `${url.pathname}${url.search}`;
        if (pinned) {
            for (const other of workers) other.playbackPins?.clear();
            instance.playbackPins = new Set([identity]);
        } else instance.playbackPins?.delete(identity);
        if (!pinned) await bundlePool.trim();
        return { applied: true, pinned: !!pinned };
    }
    return { applied: false, pinned: false };
}

const control = http.createServer(async (req, res) => {
    if (req.url?.startsWith('/hls/') || req.url?.startsWith('/media-cache/') || req.url?.startsWith('/dash-cache/') || req.url?.startsWith('/playback/') || req.url?.startsWith('/mt/')) {
        try { await mediaServices.handle(req, res); }
        catch { if (!res.headersSent) res.writeHead(502); res.end(); }
        return;
    }
    const controller = new AbortController();
    res.on('close', () => { if (!res.writableEnded) controller.abort(); });
    const reply = body => { if (res.destroyed) return; res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method !== 'POST' || req.url !== '/call' || req.headers['x-yingxia-token'] !== token) { res.writeHead(403); res.end(); return; }
    let finishSource;
    try {
        const chunks = []; let size = 0;
        for await (const chunk of req) {
            size += chunk.length;
            if (size > 48 * 1024 * 1024) { res.writeHead(413); res.end(); return; }
            chunks.push(chunk);
        }
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (input.sourceOperation === 'wait' || input.sourceOperation === 'cancelAndWait') {
            reply(await sourceFence.wait(input.operationId, input.sourceOperation === 'cancelAndWait'));
            return;
        }
        if (typeof input.sourcePlayback === 'string') {
            reply(await sourcePlayback(input.sourcePlayback, input.pinned === true));
            return;
        }
        if (typeof input.service === 'string') {
            reply({ serviceResult: await mediaServices.dispatch(input.service, input.params || {}, input.operationId) });
            return;
        }
        if (input.relocate) { reply({ result: await relocate(String(input.relocate)) }); return; }
        if (input.operationId) finishSource = sourceFence.begin(input.operationId, controller);
        if ('proxy' in input) useProxy(input.proxy);
        const key = JSON.stringify([input.bundle, input.profile]);
        const params = input.params || {};
        const releaseSearch = 'wd' in params ? await bundlePool.acquireSearch(key, controller.signal) : null;
        const searchOperation = releaseSearch ? crypto.randomUUID() : null;
        let lease;
        try {
            lease = await bundlePool.acquire(key, evict => start(input, evict), controller.signal);
            const { instance } = lease;
            await updateProxy(instance);
            await instance.alive(shareAccounts(instance, input.cloudAccounts, input.profile)).catch(error => log('CATPAW_ACCOUNT', thrownText(error)));
            if (instance.closed) throw instance.stopped();
            controller.signal.throwIfAborted();
            reply(await call(instance, params, controller.signal, searchOperation));
        } finally {
            if (releaseSearch && lease && !lease.instance.closed) await lease.instance.waitForSearchIdle(searchOperation);
            releaseSearch?.();
            await lease?.release();
        }
    } catch (error) {
        log(thrownText(error));
        reply({ error: thrownText(error), errorCode: 'script_error' });
    } finally { finishSource?.(); }
});
function announce() {
    fs.writeFileSync(controlFile + '.tmp', JSON.stringify({ port: control.address().port, token }));
    fs.renameSync(controlFile + '.tmp', controlFile);
}

// Closing a listening handle does not wait for long-running media connections.
// Error listeners are removed on both paths, including repeated wake cycles.
function listen(server, rebind = false) {
    return new Promise((resolve, reject) => {
        const failed = error => { server.off('listening', done); reject(error); };
        const done = () => { server.off('error', failed); resolve(server.address().port); };
        server.once('error', failed);
        try {
            if (rebind) server.close();
            server.listen(0, '127.0.0.1', done);
        } catch (error) { server.off('error', failed); reject(error); }
    });
}
function relistenInstance(instance) {
    if (instance.closed) return Promise.reject(instance.stopped());
    instance.relistening ??= (async () => {
        const messagesPort = await listen(instance.messages, true);
        // The worker knows whether start() has opened a source socket already,
        // including the gap before it publishes ready. It can update its bridge
        // immediately while a slow config fetch has not opened that socket yet.
        const { port, previousPort } = await instance.alive(instance.update({ messagesPort, relisten: true }));
        if (port !== undefined) {
            if (!Number.isInteger(port) || port <= 0) throw new Error('Invalid CatPawOpen server port');
            if (previousPort !== undefined) {
                if (!Number.isInteger(previousPort) || previousPort <= 0) throw new Error('Invalid previous CatPawOpen server port');
                if (!instance.ports.includes(previousPort)) instance.ports.push(previousPort);
            }
            instance.port = port;
            if (!instance.ports.includes(port)) instance.ports.push(port);
        }
    })().catch(async error => {
        await instance.terminate(error);
        throw error;
    }).finally(() => { instance.relistening = null; });
    return instance.relistening;
}
// iOS can reclaim every listening socket on suspend. Publish the fresh control
// port only after worker bridges have their new ports, with bounded RPC waits.
let relistening = null;
function relisten() {
    relistening ??= (async () => {
        await Promise.all([...workers].map(async instance => {
            if (instance.closed) return;
            await relistenInstance(instance).catch(error => log('CATPAW_RELISTEN', thrownText(error)));
        }));
        await listen(control, true);
        announce();
        log('CATPAW_RELISTEN', control.address().port);
    })().finally(() => { relistening = null; });
    return relistening;
}
fs.watch(relistenFile, () => relisten().catch(error => log('CATPAW_RELISTEN', thrownText(error))));
control.on('error', error => log('CATPAW_CONTROL', thrownText(error)));
control.listen(0, '127.0.0.1', announce);
