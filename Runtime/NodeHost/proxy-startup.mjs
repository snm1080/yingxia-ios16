import { createHash } from 'node:crypto';

// This bundle's downloader already supports a small request-relative startup
// chunk. Its ordinary cloud routes omit those options and wait for a complete
// aligned block. Keep signed URLs, source settings and sustained concurrency.
export function proxyStartupOptions(request, options) {
  if (!options || typeof options !== 'object' || typeof options.resolveUrl === 'function'
    || ['initialChunkSize','startupChunkSize','startupBytes','startupPoolSize','releaseStartupAfterFirstChunkRead']
      .some(name => options[name] !== undefined)) return options;
  if ((request.method || request.raw?.method || 'GET') !== 'GET') return options;
  const address = request.raw?.url || request.url || '';
  if (!/^\/spider\/[^/?]+\/\d+\/proxy\/(?:quark|baidu|uc)\/src\/(?:down|token)\//.test(address)) return options;
  const range = request.headers?.range;
  if (range && !/^bytes=\d+-\d*$/.test(range)) return options;
  const chunk = Number(options.chunkSize);
  if (!Number.isSafeInteger(chunk) || chunk <= 65536) return options;
  return { ...options, initialChunkSize: 65536, startupChunkSize: 65536,
    startupPoolSize: 1, releaseStartupAfterFirstChunkRead: true, requestRelativeChunks: true };
}

export const supportedProxyStartupBundleHash = '992a3990d0261122727d1c91013cd14f39f86eba290eb738902ef15d12fac067';
const entry = 'async function Hxa(e,t,r,n,a,i,s=null,o=!1,c=0){';
export function adaptProxyStartupBundle(source) {
  if (createHash('sha256').update(source).digest('hex') !== supportedProxyStartupBundleHash
    || source.split(entry).length !== 2) return { source, applied: false };
  return { source: source.replace(entry, entry + `i=(${proxyStartupOptions.toString()})(e,i);`), applied: true };
}
