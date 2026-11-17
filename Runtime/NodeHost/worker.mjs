// One CatPaw bundle per V8 isolate. Keep every local transport/compatibility
// patch here: workers do not inherit modifications to the host's globals.
import http from 'node:http';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { parentPort, workerData } from 'node:worker_threads';
import { AsyncLocalStorage } from 'node:async_hooks';
import { mobileFetch } from './mobile-fetch.mjs';
import { loadPanPasswordBundle } from './pan-password-compat.mjs';
import { runSourceRequest, installRequestCancellation, patchSourceLimiters } from './parity/lib/source-requests.mjs';
import { setProxy } from './agents.mjs';
import { request } from './http-request.mjs';
import { installDiagnostics, log, thrownText } from './diagnostics.mjs';
import { trackLocalHTTPListeners } from './local-listeners.mjs';

installDiagnostics();
globalThis.fetch = mobileFetch;
const sourceRequests = new AsyncLocalStorage();
let messagesPort = workerData.messagesPort;
let danmakuOwner;
installRequestCancellation(sourceRequests, { bridgePort: () => messagesPort });
setProxy(workerData.proxy);
globalThis.catDartServerPort = () => messagesPort;
let server, lastPort, opened = false;
let activeHTTP = 0, activeHandlers = 0, activeSearchHTTP = 0, activeSearchHandlers = 0;
const searchOperations = new Map();
const searchActivity = (operation, delta) => {
    if (!operation) return;
    const count = (searchOperations.get(operation) || 0) + delta;
    if (count > 0) searchOperations.set(operation, count); else searchOperations.delete(operation);
};
const activity = (delta, search = false, operation) => {
    activeHTTP = Math.max(0, activeHTTP + delta);
    if (search) activeSearchHTTP = Math.max(0, activeSearchHTTP + delta);
    if (search) searchActivity(operation, delta);
    parentPort.postMessage({ activity: { active: activeHTTP + activeHandlers,
        searches: activeSearchHTTP + activeSearchHandlers, searchOperations: [...searchOperations.keys()], at: Date.now() } });
};
const relistenLocal = trackLocalHTTPListeners(() => server, activity);
globalThis.catServerFactory = handler => {
    server = http.createServer((req, res) => {
        // Config-center pages use ordinary browser requests. Capture their
        // playback owner at the exact manual push trigger, before async work.
        // Delayed A callbacks retain A's token after the active page changes.
        const pathname = new URL(req.url || '/', 'http://local').pathname;
        if (danmakuOwner && !req.headers['x-wincat-play-session'] &&
            ((req.method === 'POST' && pathname === '/website/danmu/push') ||
             (req.method === 'GET' && ['/danmuput', '/website/danmu/current-play'].includes(pathname))))
            req.headers['x-wincat-play-session'] = danmakuOwner;
        patchSourceLimiters(globalThis.__CAT_JS_UTIL, sourceRequests);
        const search = req.headers['x-yingxia-search'] === '1';
        const operation = req.headers['x-yingxia-search-operation'];
        if (search) { activeSearchHandlers += 1; searchActivity(operation, 1); }
        activeHandlers += 1; activity(0);
        let result;
        try { result = runSourceRequest(sourceRequests, req, res, handler, server); }
        catch (error) { activeHandlers -= 1; if (search) { activeSearchHandlers -= 1; searchActivity(operation, -1); } activity(0); throw error; }
        Promise.resolve(result).catch(error => {
            log('CATPAW_HANDLER', thrownText(error));
            if (!res.headersSent) res.writeHead(500);
            res.end();
        }).finally(() => { activeHandlers -= 1; if (search) { activeSearchHandlers -= 1; searchActivity(operation, -1); } activity(0); });
        return result;
    });
    opened = false;
    lastPort = undefined;
    server.on('listening', () => { opened = true; lastPort = server.address().port; });
    const listen = server.listen.bind(server);
    server.listen = (...args) => listen(0, '127.0.0.1', args.find(arg => typeof arg === 'function'));
    return server;
};

// Updates are acknowledged before the host issues the next source request.
let relistening;
parentPort.on('message', async message => {
    const answer = result => parentPort.postMessage({ id: message.id, ...result });
    try {
        if (message.activityProbe) { activity(0); answer({ updated: true }); return; }
        if ('proxy' in message) setProxy(message.proxy);
        if ('messagesPort' in message) messagesPort = message.messagesPort;
        if ('danmakuOwner' in message) danmakuOwner = message.danmakuOwner;
        if (Number.isInteger(message.ensureLocalPort) && message.ensureLocalPort > 0) {
            await relistenLocal(message.ensureLocalPort);
            answer({ updated: true });
            return;
        }
        if (message.relisten && server && (opened || server.listening)) {
            relistening ??= (async () => {
                await relistenLocal();
                return await new Promise((resolve, reject) => {
                    // This port may never have reached the host's ready message:
                    // bundles can cache proxy URLs before start() returns.
                    let previousPort = lastPort;
                    try { previousPort = server.address()?.port || lastPort; } catch { /* The reclaimed native handle can report EBADF. */ }
                    const failed = error => { server.off('listening', done); reject(error); };
                    const done = () => { server.off('error', failed); resolve({ port: server.address().port, previousPort }); };
                    server.once('error', failed);
                    try {
                        server.close();
                        server.listen(done);
                    } catch (error) { server.off('error', failed); reject(error); }
                });
            })().finally(() => { relistening = null; });
            answer(await relistening);
        } else answer({ updated: true });
    } catch (error) { answer({ error: thrownText(error) }); }
});

try {
    const { bundle, api, profile } = workerData;
    fs.mkdirSync(profile, { recursive: true });
    const require = createRequire(bundle);
    let config = {};
    const local = new URL(api).hostname === 'sources.yingxia.invalid';
    try {
        const file = bundle.replace(/\.js$/, '.config.js');
        const response = local ? null : await request(api.replace(/\.js(?=$|[?#])/, '.config.js'), { timeout: 20_000 });
        const text = local ? fs.readFileSync(file, 'utf8') : response.status === 200 ? response.text : '';
        if (text) {
            if (!local) fs.writeFileSync(file, text);
            delete require.cache[file];
            const module = require(file);
            config = module?.default ?? module ?? {};
        }
    } catch (error) {
        if (local) throw error; // A verified local sibling config remains mandatory.
        log('CATPAW_CONFIG', thrownText(error));
    }
    const exports = loadPanPasswordBundle(bundle);
    if (typeof exports.start !== 'function') throw new Error('The script is not a CatPawOpen bundle');
    await exports.start(config);
    const deadline = Date.now() + 20_000;
    while (!server?.listening) {
        if (Date.now() > deadline) throw new Error('The CatPawOpen server did not start');
        await new Promise(resolve => setTimeout(resolve, 50));
    }
    parentPort.postMessage({ ready: true, port: server.address().port });
} catch (error) {
    parentPort.postMessage({ ready: false, error: thrownText(error) });
}
