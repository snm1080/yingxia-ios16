import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire, Module } from 'node:module';
import { adaptProxyStartupBundle } from './proxy-startup.mjs';

// This subscribed version drops independent share codes in three parsers. Keep
// its files/checksums intact and use its own listing/playback APIs after parsing
// the standard share query. Unknown versions continue through their own loader.
export const supportedPanBundleHash = 'f3969ba2de5f552d6c2075e7d59b3846cb28c2734b82645a4c0b21944e06de3e';
const queryCode = 'function(s){try{const u=new URL(s);return u.searchParams.get("pwd")||u.searchParams.get("password")||u.searchParams.get("accessCode")||u.searchParams.get("share_pwd")||(u.hash.match(/[?&](?:pwd|password)=([^&#]+)/)||[])[1]||""}catch{return""}}';
const replacements = [
  ['function DE(e){let t=iga.exec(e);return t?{shareId:t[1]||t[4],folderId:t[3]||t[6]||"root"}:null}',
   `function DE(e){let t=iga.exec(e);return t?{shareId:t[1]||t[4],folderId:t[3]||t[6]||"root",sharePwd:(${queryCode})(e)}:null}`],
  [String.raw`async getShareID(t,r){let n=this.regex.exec(t);if(n&&n[1]){this.shareCode=n[1];let a=this.shareCode.match(/访问码：([a-zA-Z0-9]+)/);this.accessCode=a?a[1]:""}else{let a=t.match(/https?:\/\/cloud\.189\.cn\/t\/([^&]+)/);this.shareCode=a?a[1]:null;let i=this.shareCode.match(/访问码：([a-zA-Z0-9]+)/);this.accessCode=i?i[1]:""}r&&(this.accessCode=r)}`,
   `async getShareID(t,r){const u=new URL(t);this.shareCode=u.searchParams.get("code")||u.pathname.split("/").filter(Boolean).at(-1);this.accessCode=r||(${queryCode})(t)}`],
  ['async getShareInfo(t,r){t.startsWith("http")?await this.getShareID(t,r):this.shareCode=t;try{if(r){',
   'async getShareInfo(t,r){t.startsWith("http")?await this.getShareID(t,r):this.shareCode=t;try{if(this.accessCode){'],
  ['async getShareID(t){for(let r of this.regexs){let n=r.exec(t);if(n&&n[1]){this.linkID=n[1];break}}}',
   `async getShareID(t){this.passwd=(${queryCode})(t);const u=new URL(t);u.search="";let s=u.toString();if(u.pathname==="/m/i")s=t.split("&")[0];for(let r of this.regexs){let n=r.exec(s);if(n&&n[1]){this.linkID=n[1].split(/[?&#]/)[0];break}}}`],
];

export function adaptPanPasswordBundle(source) {
  const hash = createHash('sha256').update(source).digest('hex');
  if (hash !== supportedPanBundleHash || replacements.some(([before]) => source.split(before).length !== 2))
    return { source, applied: false };
  for (const [before, after] of replacements) source = source.replace(before, after);
  return { source, applied: true };
}

export function loadPanPasswordBundle(bundle) {
  const require = createRequire(bundle);
  const filename = require.resolve(bundle);
  if (require.cache[filename]) return require.cache[filename].exports;
  const original = fs.readFileSync(filename, 'utf8');
  const passwords = adaptPanPasswordBundle(original);
  const startup = adaptProxyStartupBundle(original);
  const adapted = passwords.applied ? passwords : startup;
  if (!adapted.applied) return require(filename);
  const loaded = new Module(filename);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  require.cache[filename] = loaded;
  try { loaded._compile(adapted.source, filename); loaded.loaded = true; return loaded.exports; }
  catch (error) { delete require.cache[filename]; throw error; }
}
