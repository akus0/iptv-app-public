"""Read the simple Java Properties-compatible subset used by local .env files.

No shell evaluation or interpolation. Configuration values must never be logged.
"""
import os
import re
from pathlib import Path


def read_local_config(root):
    result = {}
    path = Path(root) / '.env'
    if path.exists():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if not line.strip() or line.lstrip().startswith(('#', '!')):
                continue
            key, separator, value = line.partition('=')
            if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key.strip()):
                raise ValueError(f'Invalid local configuration entry on line {number}')
            value = value.lstrip()
            if value.startswith(('"', "'")):
                raise ValueError(f'Use unquoted configuration values on line {number}')
            def unescape(match):
                value = match.group(1)
                return {'n': '\n', 'r': '\r', 't': '\t', 'f': '\f'}.get(value, value)
            result[key.strip()] = re.sub(r'\\(.)', unescape, value)
    return result


def local_setting(root, name):
    if name in os.environ:
        return os.environ[name]
    return read_local_config(root).get(name, '')
