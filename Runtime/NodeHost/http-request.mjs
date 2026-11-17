import http from 'node:http';
import https from 'node:https';

// nodejs-mobile's V8 runs without a JIT, so it has no WebAssembly, and Node 18's fetch (undici) needs it.
export function request(url, { method = 'GET', headers = {}, body, timeout = 60_000, signal, maximumBytes = Infinity } = {}, redirects = 5) {
    return new Promise((resolve, reject) => {
        const target = new URL(url);
        if (body !== undefined) headers = { ...headers, 'content-length': Buffer.byteLength(body) };
        const req = (target.protocol === 'https:' ? https : http).request(target, { method, headers, timeout, signal }, res => {
            if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
                res.resume();
                resolve(request(new URL(res.headers.location, target).href, { method, headers, body, timeout, signal, maximumBytes }, redirects - 1));
                return;
            }
            const chunks = [];
            let received = 0;
            const tooLarge = () => {
                chunks.length = 0;
                req.destroy(Object.assign(new Error(`The source response exceeds the ${Math.ceil(maximumBytes / 1024 / 1024)} MB search limit. Narrow the keyword and retry.`),
                    { code: 'ERR_RESPONSE_TOO_LARGE' }));
            };
            if (Number(res.headers['content-length']) > maximumBytes) { tooLarge(); return; }
            res.on('data', chunk => {
                received += chunk.length;
                if (received > maximumBytes) { tooLarge(); return; }
                chunks.push(chunk);
            });
            res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
            res.on('error', reject);
        });
        req.on('timeout', () => req.destroy(new Error(`${target.host} did not answer in time`)));
        req.on('error', reject);
        req.end(body);
    });
}

