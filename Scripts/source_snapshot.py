"""Enumerate source inputs consistently in Git checkouts and extracted source archives."""
from pathlib import Path
import os


def source_paths(root):
    root = Path(root)
    excluded = {'.git', '.build', 'build', 'artifacts', 'exports', 'node_modules',
                '__pycache__', '.swiftpm', 'xcuserdata', '.wrangler'}
    files = []
    for directory, folders, names in os.walk(root, followlinks=False):
        folders[:] = [name for name in folders if name not in excluded
                      and not name.endswith(('.xcodeproj', '.xcworkspace', '.xcframework', '.framework'))
                      and not (Path(directory) / name).is_symlink()]
        for name in names:
            path = Path(directory) / name
            if name == '.DS_Store' or name.startswith(('.env', '.dev.vars')) or name.endswith(('.pyc', '.log')):
                continue
            if path.is_file() and not path.is_symlink():
                files.append(path.relative_to(root).as_posix())
    return sorted(files)
