"""Redacted privacy checks for publishable source and optional Git history.

Never prints matched values. This supplements a dedicated secret scanner and
manual review; it cannot prove that arbitrary text or images contain no secrets.
"""
import argparse
import html
import ipaddress
import json
import os
import re
import stat
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit
from local_config import read_local_config

RULES = {
    'private-network-address': re.compile(r'\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b'),
    'personal-home-path': re.compile(r'(?:/Users/(?!AuthenticateByName\b|u1\b)[A-Za-z][\w.-]+|[A-Z]:[\\/]+Users[\\/]+[\w.-]+|/home/(?!runner\b)[\w.-]+)'),
    'private-hosting-reference': re.compile(r'(?:(?<=[\w-])\.chatgpt\.site\b|appg(?:prj|dep|ver)_[a-zA-Z0-9]+)'),
    'drive-playlist-link': re.compile(r'https?://drive\.(?:usercontent\.)?google\.com/(?:download|file/d/)[^\s\x22\x27<>]*'),
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'access-token': re.compile(r'\b(?:gh[pousr]_[a-zA-Z0-9]{30,}|github_pat_[a-zA-Z0-9_]{30,}|AKIA[A-Z0-9]{16}|sk-[a-zA-Z0-9_-]{30,})\b'),
    'webhook-secret': re.compile(r'https://discord(?:app)?\.com/api/webhooks/\d+/[\w-]+'),
    'credential-shaped-example': re.compile(r'\b(?:user(?:name)?|pass(?:word)?|pwd|psw)\s*[:=]\s*[\x22\x27]?[a-f0-9]{10,32}\b|\b[a-f0-9]{10,32}(?=Password|SmartTV)', re.I),
    'personal-request-narrative': re.compile(r'\b(?:reported|requested)(?:\s|///?)+directly\s*[:,]|\bper (?:the )?(?:direct )?feedback\b|\buser reports?\s*[:,(]', re.I),
}
URL = re.compile(r'(?:https?|rtsps?|rtmps?)://[^\s\x00-\x1f\x7f-\x9f\ufffd\x22\x27<>`]+', re.I)
# RFC-reserved examples are intentionally used in parser/security regression tests.
SYNTHETIC_HOST = re.compile(r'(?:[\w.-]*\.(?:invalid|test|example)|(?:[\w.-]+\.)?example\.(?:com|org|net)|localhost|127\.0\.0\.1)', re.I)
DOCUMENTATION_NETWORKS = tuple(ipaddress.ip_network(n) for n in (
    '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24', '2001:db8::/32'))
FORBIDDEN_SUFFIXES = {'.jks', '.keystore', '.p12', '.pfx', '.pem', '.apk', '.m3u', '.m3u8', '.db', '.sqlite', '.sqlite3',
                      '.zip', '.tar', '.gz', '.tgz', '.7z', '.rar', '.bundle', '.symbols'}
FORBIDDEN_NAMES = {'.env', 'key.properties', 'local.properties', 'HANDOFF.md'}


def source_files(root):
    raw = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-co', '--exclude-standard', '-z'])
    return sorted({p.decode() for p in raw.split(b'\0') if p})


def tracked_ignored_findings(root, values=()):
    # Ignore rules do not untrack existing files. Fail for review rather than
    # silently exporting a private file or silently dropping required source.
    raw = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-ci', '--exclude-standard', '-z'])
    return [{'path': '[redacted filename]' if scan_text(name, values) else name.decode(),
             'rule': 'tracked-ignored-file', 'line': 0}
            for name in raw.split(b'\0') if name]


def url_findings(value):
    try:
        parsed = urlsplit(html.unescape(value))
        host = parsed.hostname
    except ValueError:
        return []
    rules = []
    if host:
        try:
            address = ipaddress.ip_address(host.split('%', 1)[0])
        except ValueError:
            pass
        else:
            if not (address.is_loopback or address.is_unspecified or
                    any(address.version == n.version and address in n for n in DOCUMENTATION_NETWORKS)):
                rules.append('network-address-url')
    # Check the parsed host, not a URL prefix that could actually be userinfo.
    if host and SYNTHETIC_HOST.fullmatch(host):
        return rules
    credentials = [parsed.username, parsed.password]
    for key, values in parse_qs(parsed.query).items():
        if key.lower() in {'username', 'user', 'password', 'pass', 'pwd', 'api_key', 'access_token', 'token'}:
            credentials.extend(values)
    parts = parsed.path.strip('/').split('/')
    if len(parts) >= 4 and parts[0].lower() in {'live', 'movie', 'series', 'timeshift'}:
        credentials.extend(parts[1:3])
    elif len(parts) == 3 and re.fullmatch(r'\d+\.(?:ts|m3u8)', parts[-1], re.I):
        # Some panels omit the /live prefix from channel addresses.
        credentials.extend(parts[:2])
    # A dynamic stream id must not exempt a literal account/password elsewhere.
    for credential in credentials:
        if not credential:
            continue
        decoded = unquote(credential)
        if re.fullmatch(r'\$[A-Za-z_]\w*|\$\{[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\}', decoded):
            continue
        if re.fullmatch(r'\{[A-Za-z_]\w*\}', decoded):
            continue
        rules.append('credential-bearing-url')
        break
    return rules


def scan_text(data, private_values=()):
    # Windows exports may be Unicode text rather than UTF-8. Check the longer
    # BOM first because UTF-32 LE starts with the UTF-16 LE marker.
    encoding = ('utf-32' if data.startswith((b'\xff\xfe\0\0', b'\0\0\xfe\xff')) else
                'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8')
    text = data.decode(encoding, errors='replace')
    findings = []
    for rule, regex in RULES.items():
        for match in regex.finditer(text):
            findings.append((rule, text.count('\n', 0, match.start()) + 1))
    for match in URL.finditer(text):
        for rule in url_findings(match.group()):
            findings.append((rule, text.count('\n', 0, match.start()) + 1))
    for value in private_values:
        offset = text.find(value)
        if offset >= 0:
            findings.append(('local-configuration-value', text.count('\n', 0, offset) + 1))
    return sorted(set(findings))


def private_values(root):
    return tuple(v for v in read_local_config(root).values() if len(v) >= 8)


def read_source_entry(root, name, values=()):
    """Return the exact audited bytes and executable bit, never follow symlinks.

    Both the scanner and exporter use this path. A missing tracked file is a
    pending deletion; a directory/gitlink or other special file needs review.
    """
    root = root.resolve()
    path = root / name
    name_findings = scan_text(name.encode(), values)
    if name_findings:
        return None, 0, [{'path': '[redacted filename]', 'rule': rule, 'line': 0}
                         for rule, _ in name_findings]
    def finding(rule):
        return {'path': name, 'rule': rule, 'line': 0}
    if Path(name).is_absolute() or '..' in Path(name).parts or '.git' in Path(name).parts:
        return None, 0, [finding('source-path-outside-checkout')]
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if root in parent.parents):
        return None, 0, [finding('source-symlink-review')]
    try:
        if root not in path.resolve().parents:
            return None, 0, [finding('source-path-outside-checkout')]
        # NONBLOCK prevents a special file from hanging the audit; fstat below
        # rejects it before reading. NOFOLLOW also covers a replaced final link.
        descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    except FileNotFoundError:
        return None, 0, []
    except OSError:
        return None, 0, [finding('source-unreadable')]
    mode = os.fstat(descriptor).st_mode
    if not stat.S_ISREG(mode):
        os.close(descriptor)
        return None, 0, [finding('source-special-file-review')]
    try:
        with os.fdopen(descriptor, 'rb') as stream:
            data = stream.read()
    except OSError:
        return None, 0, [finding('source-unreadable')]
    findings = []
    if (path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES
            or (path.name.startswith('.env.') and path.name != '.env.example')):
        findings.append(finding('private-or-generated-file'))
    if data.startswith((b'PK\x03\x04', b'PK\x05\x06', b'\x1f\x8b', b'7z\xbc\xaf\x27\x1c', b'Rar!')):
        findings.append(finding('archive-content-review'))
    findings.extend({'path': name, 'rule': rule, 'line': line}
                    for rule, line in scan_text(data, values))
    return data, mode & 0o111, findings


def scan_worktree(root):
    values = private_values(root)
    findings = tracked_ignored_findings(root, values)
    count = binaries = 0
    for name in source_files(root):
        data, _, issues = read_source_entry(root, name, values)
        findings.extend(issues)
        if data is None:
            continue
        count += 1
        if b'\0' in data[:8192]:
            binaries += 1
    return {'files': count,
            'binary_files_requiring_review': binaries, 'findings': findings}


def scan_history(root):
    objects = subprocess.check_output(['git', '-C', str(root), 'rev-list', '--objects', '--all', '--reflog']).splitlines()
    proc = subprocess.Popen(['git', '-C', str(root), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    findings = []
    count = 0
    values = private_values(root)
    try:
        for entry in objects:
            oid, _, path = entry.partition(b' ')
            proc.stdin.write(oid + b'\n')
            proc.stdin.flush()
            header = proc.stdout.readline().split()
            size = int(header[2])
            data = proc.stdout.read(size)
            proc.stdout.read(1)
            if header[1] not in (b'blob', b'commit', b'tag'):
                continue
            count += 1
            name_findings = scan_text(path, values)
            display_path = '[redacted filename]' if name_findings else path.decode(errors='replace')
            findings.extend({'object': oid.decode(), 'path': display_path,
                             'rule': rule, 'line': 0} for rule, _ in name_findings)
            if header[1] == b'commit':
                for match in re.finditer(rb'(?m)^(?:author|committer) .* <([^>]+)>', data):
                    email = match.group(1).lower()
                    if b'noreply' not in email and not email.endswith(b'@example.invalid'):
                        findings.append({'object': oid.decode(), 'path': '',
                                         'rule': 'commit-email-review', 'line': 0})
            findings.extend({'object': oid.decode(), 'path': display_path,
                             'rule': rule, 'line': line}
                            for rule, line in scan_text(data, values))
    finally:
        proc.stdin.close()
        proc.stdout.close()
        proc.wait()
    return {'objects_scanned': count, 'findings': findings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true')
    parser.add_argument('--json', action='store_true', help='Redacted structured findings')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    result = scan_history(root) if args.history else scan_worktree(root)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Scanned {result.get('files', result.get('objects_scanned'))} {'history objects' if args.history else 'source files'}; {len(result['findings'])} finding(s).")
        for item in result['findings'][:100]:
            print(f"{item.get('object', '')[:12]} {item['path']}:{item['line']} [{item['rule']}]")
        if len(result['findings']) > 100:
            print('Additional findings omitted; use --json for the full redacted report.')
    return 1 if result['findings'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
