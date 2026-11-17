// Older CatPaw PGC responses wrap separate MP4 tracks in a generated MPD but
// omit codec and SegmentBase metadata. mpv can probe the original tracks itself.
export function splitProxyTracks(input, baseUrl) {
  if (!baseUrl) return null;
  try {
    const proxy = new URL(input, baseUrl);
    if (
      proxy.origin !== new URL(baseUrl).origin ||
      !/\/proxy\/?$/.test(proxy.pathname) ||
      proxy.searchParams.get('do') !== 'mpd' ||
      proxy.searchParams.has('token') ||
      proxy.searchParams.has('video_track')
    )
      return null;
    const mode = proxy.searchParams.get('mode');
    if (mode && !['dash', 'mira'].includes(mode)) return null;
    const track = (value) => {
      if (!value) return '';
      // Decode an entirely encoded URL once, never decode an already valid signed URL.
      const text = /^https?%3a/i.test(value) ? decodeURIComponent(value) : value;
      const parsed = new URL(text);
      return ['http:', 'https:'].includes(parsed.protocol) ? parsed.toString() : '';
    };
    const videoUrl = track(proxy.searchParams.get('video_url'));
    if (!videoUrl) return null;
    const audioUrl = track(proxy.searchParams.get('audio_url'));
    if (proxy.searchParams.get('audio_url') && !audioUrl) return null;
    return { videoUrl, audioUrl };
  } catch {
    return null;
  }
}
