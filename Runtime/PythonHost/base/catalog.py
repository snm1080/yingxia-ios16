"""Session-local catalog identity at the Python/native boundary."""
from collections import OrderedDict
from copy import deepcopy
import json
from urllib.parse import urlsplit

MEDIA_SUFFIXES = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus', 'mp4', 'm4v', 'mkv', 'mov',
                  'webm', 'm3u8', 'mpd', 'ts', 'm2ts', 'flv', 'avi', 'iso', 'bdmv', 'mpls'}


def normalize_player(result):
    """Some direct audio sources use playUrl as their only URL field."""
    if not isinstance(result, dict) or result.get('url') or not isinstance(result.get('playUrl'), str):
        return result
    if any(str(result.get(key) or '0').lower() not in ('0', 'false') for key in ('parse', 'jx')):
        return result
    try:
        parts = urlsplit(result['playUrl'])
    except ValueError:
        return result
    suffix = parts.path.rsplit('.', 1)[-1].lower()
    if parts.scheme in ('http', 'https') and parts.netloc and suffix in MEDIA_SUFFIXES:
        return dict(result, url=result['playUrl'], playUrl='')
    return result


def unresolved_direct_player(result):
    """Only reject bare identifiers advertised as direct input, never a parser's opaque input."""
    if not isinstance(result, dict) or not isinstance(result.get('url'), str):
        return False
    if any(str(result.get(key) or '0').lower() not in ('0', 'false') for key in ('parse', 'jx')):
        return False
    if result.get('playUrl'):
        return False
    address = result['url'].strip()
    if not address:
        return False
    try:
        parts = urlsplit(address)
    except ValueError:
        return True
    # Absolute/custom media protocols and relative HTTP paths still belong to
    # the normal native resolver. A bare server-side code cannot be demuxed.
    if parts.scheme or address.startswith(('/', './', '../')) or parts.path.rsplit('.', 1)[-1].lower() in MEDIA_SUFFIXES:
        return False
    return '/' not in parts.path and not parts.query


class CatalogState:
    """Small identity maps, independent of source names and never shared between sessions."""
    def __init__(self):
        self.posters = OrderedDict()
        self.details = OrderedDict()

    @staticmethod
    def identity(row):
        value = row.get('vod_id') if 'vod_id' in row else row.get('id')
        return str(value) if isinstance(value, (str, int)) and not isinstance(value, bool) else ''

    def normalize(self, result, detail=False):
        if not isinstance(result, dict) or not isinstance(result.get('list'), list):
            return result
        result = dict(result)
        result['list'] = [dict(row) if isinstance(row, dict) else row for row in result['list']]
        for row in result['list']:
            if not isinstance(row, dict):
                continue
            identity = self.identity(row)
            if not identity:
                continue
            if detail:
                if identity in self.posters:
                    row['vod_pic'] = deepcopy(self.posters[identity])
                    self.posters.move_to_end(identity)
                self.remember_detail(identity, row)
                continue
            picture = row.get('vod_pic', row.get('pic'))
            address = picture if isinstance(picture, str) else ''
            if isinstance(picture, dict):
                address = next((picture[key] for key in ('url', 'normal', 'large', 'medium')
                    if isinstance(picture.get(key), str) and picture[key].strip()), '')
            if not address or not address.strip() or len(json.dumps(picture, ensure_ascii=False)) > 16384:
                continue
            self.posters[identity] = deepcopy(picture)
            self.posters.move_to_end(identity)
            while len(self.posters) > 512:
                self.posters.popitem(last=False)
        return result

    def remember_detail(self, identity, row):
        flags, urls = row.get('vod_play_from'), row.get('vod_play_url')
        self.details.pop(identity, None)
        if not isinstance(flags, str) or not isinstance(urls, str) or len(urls) > 1024 * 1024:
            return
        groups = []
        count = 0
        for flag, episodes in zip(flags.split('$$$'), urls.split('$$$')):
            entries = []
            for entry in episodes.split('#'):
                if '$' not in entry:
                    continue
                name, address = entry.split('$', 1)
                if name.strip() and address:
                    entries.append((name.strip(), address))
                    count += 1
            groups.append((flag, entries))
        if count > 4096:
            return
        self.details[identity] = groups
        while len(self.details) > 8:
            self.details.popitem(last=False)

    def alternatives(self, flag, address):
        matches = []
        for groups in self.details.values():
            names = {name for candidate, entries in groups if candidate == flag for name, value in entries if value == address}
            if names:
                matches.append((groups, names))
        # Count every matching work before requiring one episode. Dropping a
        # work with a reused ID could make a different work appear unique.
        if len(matches) != 1 or len(matches[0][1]) != 1:
            return []
        groups, names = matches[0]
        name = next(iter(names))
        choices = []
        for candidate, entries in groups:
            if candidate == flag:
                continue
            matching = [(candidate, value) for label, value in entries if label == name or value == address]
            if len(matching) == 1 and matching[0] not in choices:
                choices.append(matching[0])
        return choices[:3]
