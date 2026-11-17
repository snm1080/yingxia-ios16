// Source push routing uses the same request body as MacCat's subscribed /play and /push paths.
export function pushPlayBody(params) {
    let flags = [];
    try { flags = JSON.parse(params.flags || '[]'); } catch { }
    if (!Array.isArray(flags)) flags = [];
    const input = params.url || params.link || (params.flag === 'push' ? params.play : '');
    return { flag: params.flag || '', id: params.play,
        ...(input ? { url: input, link: input, flags: flags.length ? flags : [params.flag || 'push'] } : {}) };
}

export function pushSupportResult(text) {
    let value;
    try { value = JSON.parse(text); } catch { value = text.trim(); }
    for (let depth = 0; depth < 4 && value && typeof value === 'object' && 'supported' in value; depth++) value = value.supported;
    if (value === true || value === false) return { supported: value };
    if (typeof value === 'string' && /^(?:true|false)$/i.test(value.trim())) return { supported: /^true$/i.test(value.trim()) };
    return {};
}

export async function sourcePushPlayback(send, api, body) {
    const pushed = !!body.url || body.flag === 'push';
    let text;
    try { text = await send(api + '/play', body); }
    catch (error) {
        if (!pushed || ![404, 405].includes(error.status)) throw error;
        return send(api + '/push', body);
    }
    if (!pushed) return text;
    let result;
    try { result = JSON.parse(text); } catch { return text; }
    const payload = result?.data || result?.result || result?.play || result;
    const available = payload && ['url', 'urls', 'play_url', 'playUrl', 'link', 'src', 'm3u8'].some(key => {
        const value = payload[key];
        return value !== undefined && value !== null && value !== '' && (!Array.isArray(value) || value.length > 0);
    });
    if (available) return text;
    const message = [payload?.message, payload?.error, payload?.msg, result?.message, result?.error, result?.msg]
        .find(value => typeof value === 'string' && value.trim());
    if (message) throw new Error(message);
    return send(api + '/push', body);
}
