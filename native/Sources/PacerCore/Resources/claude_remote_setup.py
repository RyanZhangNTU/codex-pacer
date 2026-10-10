"""Explicit, private Claude monitoring installation (Python 3.6+).

The caller ships the Pacer emitter; this program never downloads packages or
reads credentials. Its single stdout response contains only setup booleans or
an allowlisted error code.
"""
import base64
import json
import os
import pathlib
import stat
import sys
import uuid

LIMIT = 2 * 1024 * 1024
EVENTS = ('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
          'PostToolUseFailure', 'PermissionRequest', 'PermissionDenied', 'Stop',
          'StopFailure', 'SessionEnd', 'Notification', 'SubagentStart',
          'SubagentStop', 'Elicitation', 'ElicitationResult')
# Claude holds each displayed batch until its hooks return; numeric telemetry
# already reports TTFT, so this observer runs only without it, in background.
DISPLAY_EVENT = 'MessageDisplay'
ENVIRONMENT = {
    'CLAUDE_CODE_ENABLE_TELEMETRY': '1',
    'CLAUDE_CODE_ENHANCED_TELEMETRY_BETA': '1',
    'OTEL_TRACES_EXPORTER': 'otlp',
    'OTEL_EXPORTER_OTLP_TRACES_PROTOCOL': 'http/json',
    'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': 'http://127.0.0.1:4319/v1/traces',
    'OTEL_TRACES_EXPORT_INTERVAL': '1000'
}


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


def object_bytes(raw):
    if raw is None:
        return {}
    try:
        value = json.loads(raw.decode('utf-8'), parse_constant=invalid_constant, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        raise Failure('invalidSettings')
    if not isinstance(value, dict):
        raise Failure('invalidSettings')
    return value


def invalid_constant(value):
    raise ValueError('constant')


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate')
        value[key] = item
    return value


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


def encoded(value):
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2) + '\n').encode('utf-8')


def quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def telemetry_conflict(env):
    for source in (env, os.environ):
        if any(key in source and source[key] != value for key, value in ENVIRONMENT.items()):
            return True
        if any(source.get(key) for key in ('OTEL_EXPORTER_OTLP_HEADERS', 'OTEL_EXPORTER_OTLP_TRACES_HEADERS')):
            return True
        if ('OTEL_EXPORTER_OTLP_ENDPOINT' in source and
                source['OTEL_EXPORTER_OTLP_ENDPOINT'] not in ('http://127.0.0.1:4319', 'http://127.0.0.1:4319/')):
            return True
        if 'OTEL_EXPORTER_OTLP_PROTOCOL' in source and source['OTEL_EXPORTER_OTLP_PROTOCOL'] != 'http/json':
            return True
    return False


def ensure_owned(groups, owned, entry):
    placed = False
    result = []
    for group in groups:
        entries = group['hooks']
        if not any(owned(item) for item in entries):
            result.append(group)
            continue
        kept = []
        for item in entries:
            if not owned(item):
                kept.append(item)
            elif not placed:
                kept.append(dict(entry))
                placed = True
        if kept:
            group = dict(group)
            group['hooks'] = kept
            result.append(group)
    if not placed:
        result.append({'hooks': [dict(entry)]})
    return result


def removing_owned(groups, owned):
    result = []
    for group in groups:
        kept = [item for item in group['hooks'] if not owned(item)]
        if kept:
            group = dict(group)
            group['hooks'] = kept
            result.append(group)
    return result


def install(payload):
    path = payload.get('home')
    emitter = payload.get('hook')
    if not isinstance(path, str) or len(path) > 4096 or not isinstance(emitter, str) or len(emitter) > LIMIT:
        raise Failure('invalidPayload')
    try:
        hook_bytes = base64.b64decode(emitter, validate=True)
        hook_bytes.decode('utf-8')
    except (ValueError, UnicodeError):
        raise Failure('invalidPayload')
    if not hook_bytes or len(hook_bytes) > LIMIT:
        raise Failure('invalidPayload')
    home = pathlib.Path(path).expanduser()
    safe(home, directory=True)
    safe(home.parent, directory=True)
    directory = home / 'pacer'
    settings_path = home / 'settings.json'
    manifest_path = directory / 'installation.json'
    script_path = directory / 'hook.py'
    safe(directory, directory=True)
    safe(script_path)
    original_settings = read_bytes(settings_path)
    value = object_bytes(original_settings)
    original_manifest = read_bytes(manifest_path)
    manifest = object_bytes(original_manifest)
    hooks = value.get('hooks', {})
    env = value.get('env', {})
    if not isinstance(hooks, dict) or not isinstance(env, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in env.items()):
        raise Failure('invalidSettings')
    # The adapter uses only the standard library, so -S skips site-packages
    # startup on every hook call.
    command = 'python3 -S ' + quote(str(script_path)) + ' hook ' + quote(str(home))
    legacy_command = 'python3 ' + quote(str(script_path)) + ' hook ' + quote(str(home))
    line_command = 'python3 -S ' + quote(str(script_path)) + ' statusline ' + quote(str(home))
    legacy_line_command = 'python3 ' + quote(str(script_path)) + ' statusline ' + quote(str(home))

    def owned(entry):
        return entry.get('type') == 'command' and entry.get('command') in (command, legacy_command)
    entry = {'type': 'command', 'command': command, 'timeout': 5}
    for event in EVENTS + (DISPLAY_EVENT,):
        groups = hooks.get(event, [])
        if not isinstance(groups, list) or any(not isinstance(group, dict) or not isinstance(group.get('hooks'), list) or
                any(not isinstance(item, dict) for item in group['hooks']) for group in groups):
            raise Failure('invalidSettings')
        if event != DISPLAY_EVENT:
            hooks[event] = ensure_owned(groups, owned, entry)
    conflict = telemetry_conflict(env)
    added = manifest.get('addedEnvironment', {})
    if not isinstance(added, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in added.items()):
        raise Failure('invalidSettings')
    if not conflict:
        for key, setting in ENVIRONMENT.items():
            if key not in env:
                env[key] = setting
                added[key] = setting
        value['env'] = env
    manifest['addedEnvironment'] = added
    display = hooks.get(DISPLAY_EVENT, [])
    if all(env.get(key) == setting for key, setting in ENVIRONMENT.items()) and not conflict:
        display = removing_owned(display, owned)
    else:
        display = ensure_owned(display, owned, dict(entry, **{'async': True}))
    if display:
        hooks[DISPLAY_EVENT] = display
    else:
        hooks.pop(DISPLAY_EVENT, None)
    value['hooks'] = hooks
    previous_line = value.get('statusLine')
    if 'statusLine' in value and (not isinstance(previous_line, dict) or previous_line.get('type') != 'command' or not isinstance(previous_line.get('command'), str)):
        raise Failure('invalidSettings')
    if previous_line is not None and previous_line.get('command') == legacy_line_command:
        value['statusLine'] = dict(previous_line, command=line_command)
    elif previous_line is None or previous_line.get('command') != line_command:
        manifest['previousStatusLine'] = previous_line
        wrapper = dict(previous_line or {})
        wrapper.update(type='command', command=line_command)
        value['statusLine'] = wrapper
    manifest['version'] = 1
    if not home.exists():
        os.mkdir(str(home), 0o700)
    safe(home, directory=True)
    if not directory.exists():
        os.mkdir(str(directory), 0o700)
    safe(directory, directory=True)
    if read_bytes(settings_path) != original_settings or read_bytes(manifest_path) != original_manifest:
        raise Failure('changedSettings')
    atomic_bytes(script_path, hook_bytes, 0o700)
    if read_bytes(settings_path) != original_settings or read_bytes(manifest_path) != original_manifest:
        raise Failure('changedSettings')
    atomic_bytes(manifest_path, encoded(manifest))
    try:
        if read_bytes(settings_path) != original_settings:
            raise Failure('changedSettings')
        atomic_bytes(settings_path, encoded(value))
    except Exception:
        if original_manifest is None:
            manifest_path.unlink()
        else:
            atomic_bytes(manifest_path, original_manifest)
        raise
    return {'hooksConfigured': True,
            'telemetryConfigured': all(env.get(key) == setting for key, setting in ENVIRONMENT.items()) and not conflict,
            'statusLineConfigured': True, 'telemetryConflict': conflict}


def main():
    if sys.version_info < (3, 6):
        raise Failure('unsupportedPython')
    if len(sys.argv) != 2 or len(sys.argv[1]) > 3 * LIMIT:
        raise Failure('invalidPayload')
    try:
        raw = base64.b64decode(sys.argv[1], validate=True)
        payload = json.loads(raw.decode('utf-8'), parse_constant=invalid_constant, object_pairs_hook=unique_object)
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
