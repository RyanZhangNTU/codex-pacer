"""Pacer's Codex progress tool on an SSH or WSL host (Python 3.6+).

Codex starts MCP servers from the host's own config.toml, so a task that runs
here can report its estimate only through a server registered here. The
caller ships the reporter; this program never downloads packages or reads
credentials. Pacer owns one marked table in config.toml, the reporter under
<home>/pacer/codex-progress/remote and the enabled flag the reporter reads.
A same-name entry Pacer did not write, or a marked table someone edited, is
left alone and reported as a conflict. Unchanged content is never rewritten.
The single stdout response holds only booleans or an allowlisted error code.
"""
import base64
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
import uuid

LIMIT = 2 * 1024 * 1024
SERVER = 'pacer_progress'
OWNER = 'codex-pacer-progress-v2'
BEGIN = '# BEGIN Codex Pacer progress tool. Codex Pacer manages this table; editing it makes it yours.'
END = '# END Codex Pacer progress tool sha256:'
ON = b'on\n'
# A table Pacer adds after these would redefine or extend a value it does not own.
FOREIGN = re.compile(r'pacer_progress')
INLINE_SERVERS = re.compile(r'^\s*(?:mcp_servers\s*=|\[\[\s*mcp_servers\s*\]\])')


class Failure(Exception):
    pass


def safe(path, directory=False):
    if not path.is_absolute() or any(ord(char) < 32 or ord(char) == 127 for char in str(path)):
        raise Failure('unsafePath')
    # Ancestor links would let otherwise safe final files escape their folder.
    for parent in (path,) + tuple(path.parents):
        try:
            attrs = os.lstat(str(parent))
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(attrs.st_mode):
            raise Failure('unsafePath')
        if parent == path:
            expected = stat.S_ISDIR(attrs.st_mode) if directory else stat.S_ISREG(attrs.st_mode)
            if attrs.st_uid != os.getuid() or not expected:
                raise Failure('unsafePath')
        elif not stat.S_ISDIR(attrs.st_mode):
            raise Failure('unsafePath')


def read_bytes(path):
    safe(path)
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'rb') as handle:
        attrs = os.fstat(handle.fileno())
        if attrs.st_uid != os.getuid() or not stat.S_ISREG(attrs.st_mode):
            raise Failure('unsafePath')
        raw = handle.read(LIMIT + 1)
    if len(raw) > LIMIT:
        raise Failure('invalidSettings')
    return raw


def atomic_bytes(path, raw, permissions=0o600):
    safe(path)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(str(temporary), os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(raw)
            handle.flush()
            os.fchmod(handle.fileno(), permissions)
            os.fsync(handle.fileno())
        safe(path)
        os.replace(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def remove(path):
    safe(path)
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def folder(path):
    if not path.exists():
        os.mkdir(str(path), 0o700)
    safe(path, directory=True)


def toml_string(value):
    # A JSON string with ASCII escapes is a valid TOML basic string.
    return json.dumps(value, ensure_ascii=True)


def table(python, reporter, home):
    args = ', '.join(toml_string(value) for value in ('-I', '-S', str(reporter), str(home)))
    body = ['[mcp_servers.%s]' % SERVER,
            'command = ' + toml_string(python),
            'args = [' + args + ']',
            'env = { PACER_CODEX_PROGRESS_OWNER = ' + toml_string(OWNER) + ' }',
            # Tool-search models would otherwise find the tool only through tool_search.
            'omit_tools_from = ["deferred"]']
    return body


def checksum(body):
    return hashlib.sha256('\n'.join(body).encode('utf-8')).hexdigest()


def block(body):
    return [BEGIN] + body + [END + checksum(body)]


def split(text):
    """Returns the lines outside Pacer's table, its body and where it was.

    The body is None when there is no table, and False when its markers are
    damaged or its content no longer matches the checksum Pacer wrote."""
    lines = text.split('\n')
    starts = [index for index, line in enumerate(lines) if line.rstrip('\r') == BEGIN]
    if not starts:
        return lines, None, len(lines)
    if len(starts) > 1:
        return lines, False, starts[0]
    start = starts[0]
    for end in range(start + 1, len(lines)):
        line = lines[end].rstrip('\r')
        if line.startswith(END):
            body = [value.rstrip('\r') for value in lines[start + 1:end]]
            if line[len(END):] != checksum(body):
                return lines, False, start
            return lines[:start] + lines[end + 1:], body, start
        if line.startswith('# BEGIN Codex Pacer') or line.startswith('# END Codex Pacer'):
            break
    return lines, False, start


def foreign(lines):
    for line in lines:
        content = line.split('#', 1)[0]
        if FOREIGN.search(content) or INLINE_SERVERS.match(content):
            return True
    return False


def compose(outside, at, body):
    """Puts Pacer's table back where it was, or after everything else."""
    lines = list(outside)
    if body is None:
        while lines and lines[-1].strip() == '' and at >= len(lines):
            lines.pop()
        return '\n'.join(lines).rstrip('\n') + ('\n' if any(line.strip() for line in lines) else '')
    owned = block(body)
    if at >= len(lines):
        while lines and lines[-1].strip() == '':
            lines.pop()
        if lines:
            lines.append('')
        return '\n'.join(lines + owned) + '\n'
    return '\n'.join(lines[:at] + owned + lines[at:])


def install(payload):
    path = payload.get('home')
    enabled = payload.get('enabled')
    reporter = payload.get('reporter')
    if not isinstance(path, str) or not path or len(path) > 4096 or not isinstance(enabled, bool):
        raise Failure('invalidPayload')
    reporter_bytes = b''
    if enabled:
        if not isinstance(reporter, str) or len(reporter) > LIMIT:
            raise Failure('invalidPayload')
        try:
            reporter_bytes = base64.b64decode(reporter, validate=True)
            reporter_bytes.decode('utf-8')
        except (ValueError, UnicodeError):
            raise Failure('invalidPayload')
        if not reporter_bytes:
            raise Failure('invalidPayload')
    home = pathlib.Path(path).expanduser()
    if not home.is_absolute():
        raise Failure('unsafePath')
    # A host without Codex is skipped rather than given a new Codex home.
    if not home.is_dir():
        if enabled:
            raise Failure('missingHome')
        return {'configured': False, 'conflict': False}
    safe(home, directory=True)
    pacer = home / 'pacer'
    progress = pacer / 'codex-progress'
    native = progress / 'native'
    remote = progress / 'remote'
    flag = native / 'enabled'
    script = remote / 'pacer-codex-progress.py'
    config = home / 'config.toml'
    for directory in (pacer, progress, native, remote):
        safe(directory, directory=True)
    for file in (flag, script, config):
        safe(file)
    original = read_bytes(config)
    try:
        text = (original or b'').decode('utf-8')
    except UnicodeError:
        raise Failure('invalidSettings')
    outside, current, at = split(text)
    conflict = current is False or foreign(outside)

    if not enabled:
        # Reporting stops at once; then only Pacer's own entries go.
        if read_bytes(flag) == ON:
            remove(flag)
        if current and not conflict:
            if read_bytes(config) != original:
                raise Failure('changedSettings')
            atomic_bytes(config, compose(outside, at, None).encode('utf-8'), stat.S_IMODE(os.lstat(str(config)).st_mode))
        if read_bytes(script) is not None:
            remove(script)
        return {'configured': False, 'conflict': conflict}

    if conflict:
        # Someone else's entry wins; Pacer's reporter stays off for it.
        if read_bytes(flag) == ON:
            remove(flag)
        return {'configured': False, 'conflict': True}
    python = sys.executable if sys.executable and os.path.isabs(sys.executable) else 'python3'
    wanted = table(python, script, home)
    for directory in (pacer, progress, native, remote):
        folder(directory)
    if read_bytes(script) != reporter_bytes:
        atomic_bytes(script, reporter_bytes)
    if current != wanted:
        if read_bytes(config) != original:
            raise Failure('changedSettings')
        mode = stat.S_IMODE(os.lstat(str(config)).st_mode) if original is not None else 0o600
        atomic_bytes(config, compose(outside, at, wanted).encode('utf-8'), mode)
    # The flag goes last, so the reporter offers its tool only once registered.
    if read_bytes(flag) != ON:
        atomic_bytes(flag, ON)
    return {'configured': True, 'conflict': False}


def invalid_constant(value):
    raise ValueError('constant')


def main():
    if sys.version_info < (3, 6):
        raise Failure('unsupportedPython')
    if len(sys.argv) != 2 or len(sys.argv[1]) > 3 * LIMIT:
        raise Failure('invalidPayload')
    try:
        raw = base64.b64decode(sys.argv[1], validate=True)
        payload = json.loads(raw.decode('utf-8'), parse_constant=invalid_constant)
    except (ValueError, UnicodeError):
        raise Failure('invalidPayload')
    if len(raw) > LIMIT or not isinstance(payload, dict):
        raise Failure('invalidPayload')
    return install(payload)


if __name__ == '__main__':
    try:
        result = main()
    except Failure as failure:
        result = {'error': str(failure)}
    except Exception:
        result = {'error': 'setupFailed'}
    sys.stdout.write(json.dumps(result, separators=(',', ':')) + '\n')
    sys.stdout.flush()
    sys.exit(1 if 'error' in result else 0)
