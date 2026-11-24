"""Codex for Claude: Pacer's runner for Claude Code's /pacer:codex skill.

One `codex exec` process per call (task, resume, review). Every run belongs to
the Claude session that started it (CLAUDE_CODE_SESSION_ID) and lives in
<root>/runs/<session>/<run>/, where <root> is this file's folder. meta.json
there is the run's ledger entry: identifiers, times, parameters and status,
never the brief or Codex's output, which stay beside it. Pacer reads the
ledger to show each run under its Claude task.

How long a run's Codex threads stay is the user's choice in Pacer (config.json
`records`): `turn` deletes finished runs after a Stop with no background work
and a confirming transcript summary. The detached `turn-end` waits for that
summary. With `timed`, the next run start or confirmed turn end in the session
deletes records past `recordsHours`. With `keep`, threads stay in Codex's
history. Deleting a run removes its thread and sub-threads
(`codex delete --force`), its Codex worktree and its run folder. A worktree
that still holds changes nobody applied or discarded
stays until its Claude session is gone; then its changes are saved as a patch
under <root>/patches before the worktree is removed. Run starts and explicit
cleanup sweep other sessions. A Stop with no background work in any Claude
session also starts a detached sweep when other sessions or queued deletions
remain, at most once every ten minutes.

Pacer rewrites this file with each release. Python 3.9 or later, standard
library only.
"""
from contextlib import contextmanager
import signal
import json, os, re, shutil, subprocess, sys, threading, time
from pathlib import Path

ROOT = Path(os.path.abspath(__file__)).parent
RUNS = ROOT / 'runs'
PENDING = ROOT / 'pending-deletes.txt'
QUOTA = ROOT / 'quota.json'
PATCHES = ROOT / 'patches'
CONFIG = ROOT / 'config.json'
ORIGINATOR = 'Codex Pacer'
KNOWN_EFFORTS = ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
FAST_TIER, STANDARD_TIER = 'priority', 'default'
MAX_PRINT = 20000
STALE = 48 * 3600
SAFETY_MINUTES = 360.0  # a stuck Codex process; there is no user setting for this
LEVELS = ('read-only', 'workspace-write', 'workspace-write-network', 'danger-full-access')
RECORD_HOURS = (2, 6, 12, 24, 48, 72, 168)
MAX_INSTRUCTIONS = 4000
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
SAFE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
WINDOWS = os.name == 'nt'
NO_WINDOW = 0x08000000

USAGE = """Usage (RUN is the command your skill gives):
  RUN [task] [options] (-f - <<'EOF' … EOF | -f <brief-file> | <prompt text>)
  RUN resume <thread-id|last> [options] (-f - | -f <file> | <text>)
  RUN review (--uncommitted | --base <branch> | --commit <sha>) [--title <t>] [options] [-f <file>]
  RUN models [--json]        models, efforts, fast tiers and config defaults
  RUN runs                   this Claude session's runs
  RUN stop <thread-id>       stop a running job
  RUN apply <thread-id>      copy a --worktree run's changes into its repo
  RUN discard <thread-id>    drop a --worktree run's changes at cleanup
  RUN cleanup                delete this session's finished runs now

Options:
  -f, --prompt-file <file>  UTF-8 brief for Codex; - reads it from standard input
  -l, --label <text>        a few words Pacer shows for this run, e.g. "Review login changes"
  -m, --model <slug>        model, e.g. gpt-6.2-sol (see: models)
  -e, --effort <level>      """ + ' | '.join(KNOWN_EFFORTS) + """
      --fast | --no-fast    force the Fast service tier on or off
      --write | --read-only let Codex change files (up to Pacer's file access) or not
      --worktree            run in a new Codex-managed git worktree (with --write; needs a git repository)
  -C, --cd <dir>            working root (default: current directory; need not be a git repository)
  -i, --image <file>        attach an image (task/resume; repeatable)
      --timeout <minutes>   stop the job after this long (default: 360)
      --dry-run             print the codex command line and exit
With a review brief or standing instructions, the review scope and title go into the prompt.
Defaults for model, effort, fast mode, file access and work location come from
Pacer's settings; a run never gets more file access than they allow.
"""


def fail(message, code=2):
    sys.stderr.write('pacer-codex: ' + message + '\n')
    sys.stderr.flush()
    sys.exit(code)


def ident(value):
    return value if isinstance(value, str) and SAFE.match(value) else None


SESSION = ident(os.environ.get('CLAUDE_CODE_SESSION_ID')) or 'manual'
try:
    OWNER = int(os.environ.get('CLAUDE_PID') or 0) or None
except ValueError:
    OWNER = None


def config():
    try:
        value = json.loads(CONFIG.read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def level(settings):
    value = settings.get('sandbox')
    return value if value in LEVELS else 'workspace-write-network'


def records(settings):
    """How long finished runs stay: ('turn'|'timed'|'keep', hours)."""
    mode = settings.get('records') if settings.get('records') in ('turn', 'timed', 'keep') else 'turn'
    hours = settings.get('recordsHours')
    return mode, (hours if hours in RECORD_HOURS else 24)


def instructions(settings):
    value = settings.get('instructions')
    return value.strip()[:MAX_INSTRUCTIONS] if isinstance(value, str) else ''


def runner_command():
    command = config().get('command')
    if command:
        return command
    def quoted(part):
        part = part.replace('\\', '/')
        return '"' + part + '"' if ' ' in part else part
    return ' '.join(quoted(part) for part in [sys.executable, '-S', os.path.abspath(__file__)])

# ---------------------------------------------------------------- arguments


class Options:
    def __init__(self):
        self.mode = 'task'; self.target = None; self.model = None; self.effort = None; self.fast = None
        self.write = None; self.worktree = False; self.worktree_setting = False; self.cd = None; self.images = []; self.timeout = None
        self.prompt_file = None; self.review = None; self.title = None; self.dry_run = False; self.text = []
        self.label = None; self.json = False; self.session = None
        self.transcript = None; self.cursor = None
        self.level = 'read-only'; self.memory = False


MAINTENANCE = ('models', 'runs', 'stop', 'apply', 'discard', 'cleanup', 'turn-end', 'sweep', 'doctor')


def parse(argv):
    o = Options()
    modes = ('task', 'resume', 'review', 'models', 'runs', 'stop', 'apply', 'discard', 'cleanup', 'turn-end', 'sweep', 'doctor')
    i = 0
    if argv and argv[0] in modes:
        o.mode = argv[0]; i = 1
    if o.mode in ('resume', 'stop', 'apply', 'discard'):
        if i >= len(argv) or argv[i].startswith('-'):
            fail(o.mode + ' needs a thread id' + (" or 'last'" if o.mode == 'resume' else ''))
        o.target = argv[i]; i += 1
    while i < len(argv):
        a = argv[i]

        def value():
            if i + 1 >= len(argv):
                fail(a + ' needs a value')
            return argv[i + 1]
        if a in ('-f', '--prompt-file'): o.prompt_file = value(); i += 1
        elif a in ('-l', '--label'): o.label = value(); i += 1
        elif a in ('-m', '--model'): o.model = value(); i += 1
        elif a in ('-e', '--effort'): o.effort = value().lower(); i += 1
        elif a == '--fast': o.fast = True
        elif a == '--no-fast': o.fast = False
        elif a == '--write': o.write = True
        elif a == '--read-only': o.write = False
        elif a == '--worktree': o.worktree = True
        elif a in ('-C', '--cd'): o.cd = value(); i += 1
        elif a in ('-i', '--image'): o.images.append(value()); i += 1
        elif a == '--timeout':
            try: o.timeout = float(value())
            except ValueError: fail('--timeout must be a number of minutes')
            i += 1
        elif a == '--uncommitted': o.review = ['--uncommitted']
        elif a == '--base': o.review = ['--base', value()]; i += 1
        elif a == '--commit': o.review = ['--commit', value()]; i += 1
        elif a == '--title': o.title = value(); i += 1
        elif a == '--json': o.json = True
        elif a == '--session': o.session = ident(value()) or fail('invalid session'); i += 1
        elif a == '--transcript': o.transcript = value(); i += 1
        elif a == '--cursor':
            try: o.cursor = json.loads(value())
            except ValueError: fail('invalid transcript cursor')
            i += 1
        elif a == '--dry-run': o.dry_run = True
        elif a in ('-h', '--help'): sys.stdout.write(USAGE); sys.exit(0)
        elif a == '--': o.text.extend(argv[i + 1:]); break
        elif a.startswith('-') and len(a) > 1: fail('unknown option ' + a + ' (see --help)')
        else: o.text.append(a)
        i += 1
    settings = config()
    if o.timeout is None:
        o.timeout = SAFETY_MINUTES
    if o.timeout <= 0:
        fail('--timeout must be a positive number of minutes')
    if o.mode == 'review' and not o.review:
        fail('review needs --uncommitted, --base <branch> or --commit <sha>')
    if o.worktree and o.mode in ('review', 'resume'):
        fail('--worktree is only available for a new task')
    if o.mode == 'review' and o.write:
        fail('review is read-only; drop --write')
    if o.worktree and o.write is False:
        fail('--worktree cannot be used with --read-only')
    allowed = level(settings)
    if o.worktree:
        o.write = True
    if o.write and allowed == 'read-only' and o.mode not in MAINTENANCE:
        fail('file access is read-only in Pacer (Settings → Collaboration); run without --write, or ask the user to allow writing there.', 4)
    if o.write is None:
        o.write = o.mode != 'review' and allowed != 'read-only'
    if o.write and not o.worktree and o.mode == 'task' and settings.get('worktree') is True:
        o.worktree = o.worktree_setting = True
    o.level = allowed if o.write else 'read-only'
    o.memory = settings.get('memory') is True
    if o.model is None and isinstance(settings.get('model'), str) and settings['model']:
        o.model = settings['model']
    if o.effort is None and isinstance(settings.get('effort'), str) and settings['effort']:
        o.effort = settings['effort']
    if o.fast is None and isinstance(settings.get('fast'), bool):
        o.fast = settings['fast']
    if o.effort and o.effort not in KNOWN_EFFORTS:
        sys.stderr.write('pacer-codex: warning: effort "' + o.effort + '" is not one of ' + '/'.join(KNOWN_EFFORTS) + '; passing it through\n')
    if o.label is not None:
        o.label = ' '.join(o.label.split())[:60] or None
    return o


def read_prompt(o):
    if o.prompt_file == '-':
        # A quoted heredoc keeps the brief out of the project and away from shell quoting.
        try:
            return sys.stdin.buffer.read().decode('utf-8-sig', 'replace')
        except (OSError, ValueError) as error:
            fail('cannot read the brief from standard input: ' + str(error))
    if o.prompt_file:
        try:
            with open(o.prompt_file, 'r', encoding='utf-8-sig') as handle:
                return handle.read()
        except OSError as error:
            fail('cannot read prompt file: ' + str(error))
    return ' '.join(o.text)

# ---------------------------------------------------------------- processes


def resolve_codex():
    """The Codex program: CODEX_BIN, the one Pacer found, then PATH."""
    candidates = []
    if os.environ.get('CODEX_BIN'):
        candidates.append(os.environ['CODEX_BIN'])
    chosen = config().get('codex')
    if isinstance(chosen, str) and chosen:
        candidates.append(chosen)
    for path in candidates:
        if WINDOWS and re.match(r'^/[A-Za-z]:[\\/]', path):
            path = path[1:]
        if os.path.isfile(path):
            return [path]
    if not WINDOWS:
        found = shutil.which('codex')
        return [found] if found else None
    for folder in (os.environ.get('PATH') or '').split(os.pathsep):
        folder = folder.strip().strip('"')
        if not folder:
            continue
        exe = os.path.join(folder, 'codex.exe')
        if os.path.isfile(exe):
            return [exe]
        # An npm global install: codex.cmd beside node_modules, whose platform
        # package carries the native program.
        packages = os.path.join(folder, 'node_modules', '@openai', 'codex', 'node_modules', '@openai')
        try:
            for name in sorted(os.listdir(packages)):
                if not name.startswith('codex-win32-'):
                    continue
                vendor = os.path.join(packages, name, 'vendor')
                for target in sorted(os.listdir(vendor)):
                    for relative in (('bin', 'codex.exe'), ('codex', 'codex.exe')):
                        exe = os.path.join(vendor, target, *relative)
                        if os.path.isfile(exe):
                            return [exe]
        except OSError:
            pass
    return None


def codex_home():
    return Path(os.environ.get('CODEX_HOME') or os.path.join(os.path.expanduser('~'), '.codex'))


def config_defaults():
    found = {}
    try:
        for line in (codex_home() / 'config.toml').read_text(encoding='utf-8').splitlines():
            if line.lstrip().startswith('['):
                break
            match = re.match(r'^\s*(model|model_reasoning_effort|service_tier)\s*=\s*"([^"]*)"', line)
            if match:
                found[match.group(1)] = match.group(2)
    except OSError:
        pass
    return found


def alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    if WINDOWS:
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ctypes.get_last_error() == 5  # access denied: it exists
        try:
            code = wintypes.DWORD()
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259  # STILL_ACTIVE
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def kill_tree(process):
    if process is None or process.poll() is not None:
        return
    if WINDOWS:
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
    else:
        import signal
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            process.terminate()
    try:
        process.wait(10)
    except subprocess.TimeoutExpired:
        process.kill()


def bind_to_runner(process):
    """On Windows, Codex leaves with this runner: a job object that closes with
    this process ends Codex too, even when Claude stops the runner outright."""
    if not WINDOWS:
        return None
    try:
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        job = kernel.CreateJobObjectW(None, None)
        if not job:
            return None

        class Basic(ctypes.Structure):
            _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64),
                        ('LimitFlags', wintypes.DWORD), ('MinimumWorkingSetSize', ctypes.c_size_t),
                        ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', wintypes.DWORD),
                        ('Affinity', ctypes.c_size_t), ('PriorityClass', wintypes.DWORD), ('SchedulingClass', wintypes.DWORD)]

        class Counters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ('a', 'b', 'c', 'd', 'e', 'f')]

        class Extended(ctypes.Structure):
            _fields_ = [('BasicLimitInformation', Basic), ('IoInfo', Counters), ('ProcessMemoryLimit', ctypes.c_size_t),
                        ('JobMemoryLimit', ctypes.c_size_t), ('PeakProcessMemoryUsed', ctypes.c_size_t),
                        ('PeakJobMemoryUsed', ctypes.c_size_t)]
        info = Extended()
        info.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(wintypes.HANDLE(job), 9, ctypes.byref(info), ctypes.sizeof(info)):
            kernel.CloseHandle(wintypes.HANDLE(job))
            return None
        handle = kernel.OpenProcess(0x0101, False, process.pid)  # PROCESS_SET_QUOTA | PROCESS_TERMINATE
        if handle:
            kernel.AssignProcessToJobObject(wintypes.HANDLE(job), wintypes.HANDLE(handle))
            kernel.CloseHandle(wintypes.HANDLE(handle))
        return job  # kept open for this process's lifetime
    except (AttributeError, OSError, ValueError):
        return None


def codex_args(o, last_file, has_prompt, resume_id):
    args = ['exec']
    if o.mode in ('resume', 'review'):
        args.append(o.mode)
    args += ['--json', '-o', last_file]
    if not o.memory:
        args += ['--disable', 'memories']
    if o.model:
        args += ['-m', o.model]
    if o.effort:
        args += ['-c', 'model_reasoning_effort="' + o.effort + '"']
    if o.fast is not None:
        args += ['-c', 'service_tier="' + (FAST_TIER if o.fast else STANDARD_TIER) + '"']
    sandbox = 'read-only' if o.mode == 'review' else 'danger-full-access' if o.level == 'danger-full-access' else 'workspace-write' if o.write else 'read-only'
    args += ['-c', 'sandbox_mode="' + sandbox + '"', '-c', 'approval_policy="never"']
    if sandbox != 'read-only':
        network = o.level in ('workspace-write-network', 'danger-full-access')
        args += ['-c', 'sandbox_workspace_write.network_access=' + str(network).lower()]
    if o.worktree:
        args.append('--worktree')
    # Pacer sets file access on every call, so a folder that isn't a git
    # repository (a scratch workspace, a plain folder) is fine to work in.
    args.append('--skip-git-repo-check')
    if o.mode != 'review':
        for image in o.images:
            args += ['-i', image]
    if o.mode == 'resume':
        args.append(resume_id)
    if o.mode == 'review' and not has_prompt:
        args += o.review
        if o.title:
            args += ['--title', o.title]
    if has_prompt:
        args.append('-')
    return args


def run_quiet(command, cwd=None, timeout=60):
    options = {'stdin': subprocess.DEVNULL, 'stdout': subprocess.PIPE, 'stderr': subprocess.STDOUT, 'cwd': cwd, 'timeout': timeout}
    if WINDOWS:
        options['creationflags'] = NO_WINDOW
    try:
        return subprocess.run(command, **options)
    except (OSError, subprocess.SubprocessError):
        return None

# ---------------------------------------------------------------- Codex threads


def rollout_index(at=None, home=None):
    index = {}
    root = (Path(home) if home else codex_home()) / 'sessions'
    seen = set()
    now = at or time.time()
    for offset in (0, -1, -2, 1):
        stamp = now + offset * 86400
        for parts in (time.localtime(stamp), time.gmtime(stamp)):
            folder = root / ('%04d' % parts.tm_year) / ('%02d' % parts.tm_mon) / ('%02d' % parts.tm_mday)
            if folder in seen:
                continue
            seen.add(folder)
            try:
                names = os.listdir(folder)
            except OSError:
                continue
            for name in names:
                ids = UUID.findall(name)
                if ids and name.endswith('.jsonl'):
                    index[ids[-1]] = folder / name
    return index


def turn_context(rollout):
    context = None
    if not rollout:
        return None
    try:
        with open(rollout, 'r', encoding='utf-8', errors='replace') as handle:
            for line in handle:
                if '"turn_context"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get('type') == 'turn_context' and isinstance(entry.get('payload'), dict):
                    context = entry['payload']
    except OSError:
        pass
    return context


def child_threads(parent, index, found=None):
    """Sub-threads (the reviewer a review spawns) name their parent in their
    first line; `codex delete` leaves them, so they are found here."""
    found = set() if found is None else found
    rollout = index.get(parent)
    if not rollout:
        return found
    try:
        text = rollout.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return found
    for thread in set(UUID.findall(text)):
        if thread == parent or thread in found or thread not in index:
            continue
        try:
            with open(index[thread], 'r', encoding='utf-8', errors='replace') as handle:
                first = handle.readline()
        except OSError:
            continue
        if '"parent_thread_id":"' + parent + '"' in first:
            found.add(thread)
            child_threads(thread, index, found)
    return found


def delete_thread(codex, thread):
    if not CONFIG.exists():
        return True  # pairing disabled: forget the request, keep the thread
    if not codex:
        return False
    result = run_quiet(codex + ['delete', '--force', thread])
    # "failed to delete session" also comes back for threads already gone.
    return (result is not None and result.returncode == 0) or thread not in rollout_index()


def delete_threads(codex, threads):
    if not threads:
        return []
    results = {}
    workers = [threading.Thread(target=lambda t=t: results.__setitem__(t, delete_thread(codex, t))) for t in threads]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    return [t for t in threads if not results.get(t)]

# ---------------------------------------------------------------- git


def git(cwd, args):
    result = run_quiet(['git'] + args, cwd=cwd, timeout=120)
    if result is None or result.returncode != 0:
        return None
    return result.stdout.decode('utf-8', 'replace')


def toplevel(folder):
    value = git(folder, ['rev-parse', '--show-toplevel'])
    return value.strip() if value else None


SKIP_FOLDERS = {'node_modules', 'venv', '__pycache__'}
SCAN_FILES, SCAN_DEPTH = 5000, 8


def folder_snapshot(folder):
    """Outside a repository: every file's size and time, skipping hidden and
    dependency folders, or None when the tree passes SCAN_FILES files."""
    base = os.path.abspath(folder)
    entries = {}
    for current, folders, files in os.walk(base):
        relative = os.path.relpath(current, base)
        depth = 0 if relative == '.' else relative.count(os.sep) + 1
        folders[:] = [name for name in folders if name not in SKIP_FOLDERS and not name.startswith('.')] if depth < SCAN_DEPTH else []
        for name in files:
            path = os.path.join(current, name)
            try:
                stat = os.stat(path)
            except OSError:
                continue
            entries[os.path.relpath(path, base).replace(os.sep, '/')] = ('', '%d:%d' % (stat.st_size, stat.st_mtime_ns))
            if len(entries) > SCAN_FILES:
                return None
    return {'root': base, 'entries': entries, 'plain': True}


def snapshot(folder):
    """Every dirty or untracked file with a cheap signature; outside a
    repository, every file (folder_snapshot). Two snapshots catch edits made
    through shell commands."""
    root = toplevel(folder)
    if not root:
        return folder_snapshot(folder) if folder and os.path.isdir(folder) else None
    status = git(folder, ['status', '--porcelain=v1', '-z', '--untracked-files=all'])
    if status is None:
        return None
    entries = {}
    records = status.split('\0')
    i = 0
    while i < len(records):
        record = records[i]; i += 1
        if not record:
            continue
        code = record[:2].strip() or 'M'
        if record[0] in 'RC':
            i += 1  # the next record is the rename or copy source
        name = record[3:]
        try:
            stat = os.stat(os.path.join(root, name))
            signature = '%d:%d' % (stat.st_size, stat.st_mtime_ns)
        except OSError:
            signature = 'missing'
        entries[name] = (code, signature)
    head = (git(root, ['rev-parse', '--verify', 'HEAD']) or '').strip() or None
    return {'root': root, 'entries': entries, 'head': head}


def change_path(name, cwd):
    try:
        relative = os.path.relpath(name, cwd) if os.path.isabs(name) else name
    except ValueError:  # Windows paths on different drives
        return name
    return relative.replace(os.sep, '/') if not relative.startswith('..') else name


def changed_between(before, after):
    old = before['entries'] if before else {}
    if after.get('plain'):
        # A plain folder: added, modified and deleted files.
        changed = []
        for name, now in after['entries'].items():
            if old.get(name) != now:
                changed.append(('M ' if name in old else 'A ') + name)
        return changed + ['D ' + name for name in old if name not in after['entries']]
    by_path = {}
    renamed = set()
    if before and after.get('head') and before.get('head') != after['head']:
        root = after['root']
        # An unborn branch starts at the empty tree (in the repository's hash format).
        base = before.get('head') or (git(root, ['hash-object', '-t', 'tree', '--stdin']) or '').strip()
        diff = git(root, ['diff', '--name-status', '-z', base, after['head'], '--'])
        if diff is None:
            return None
        fields = iter(diff.split('\0')[:-1])
        for code in fields:
            name = next(fields)
            if code.startswith(('R', 'C')):
                source, name = name, next(fields)
                if code.startswith('R'):
                    renamed.add(source)
                by_path[name] = ' '.join((code, source, name))
            else:
                by_path[name] = code + ' ' + name
    for name, now in after['entries'].items():
        if old.get(name) != now:
            by_path.setdefault(name, now[0] + ' ' + name)
    for name in old:
        if name not in after['entries'] and name not in renamed:
            by_path.setdefault(name, 'reverted ' + name)
    return list(by_path.values())


def worktree_paths(folder):
    out = git(folder, ['worktree', 'list', '--porcelain']) or ''
    return [os.path.normcase(os.path.abspath(line[9:].strip())) for line in out.splitlines() if line.startswith('worktree ')]


def record_worktree(run, context=None, persist=True):
    """Records a worktree run's tree from its thread's rollout. Returns whether
    the thread's folder is known, as a worktree or not, so a lookup can stop."""
    # Older ledgers only recorded the starting revision for worktree runs.
    if run.get('worktree') or not run.get('worktreeRequested', run.get('worktreeBase')) or not run.get('thread'):
        return bool(run.get('worktree'))
    if context is None:
        index = rollout_index(run.get('created'), run.get('codexHome'))
        context = turn_context(index.get(run['thread'])) or {}
    if not context.get('cwd'):
        return False
    tree = toplevel(context['cwd'])
    repo = toplevel(run['cwd']) if tree and run.get('cwd') else None
    if repo and os.path.normcase(tree) != os.path.normcase(repo) and os.path.normcase(tree) in worktree_paths(repo):
        run['worktree'] = tree
        if persist:
            save(run)
    return True


def remove_worktree(run):
    tree = run.get('worktree')
    if not tree or not os.path.isdir(tree):
        return
    cwd = run.get('cwd') or None
    git(cwd, ['worktree', 'remove', '--force', tree])
    shutil.rmtree(tree, ignore_errors=True)
    git(cwd, ['worktree', 'prune'])
    parent = os.path.dirname(tree)
    try:
        if os.path.normcase(os.path.dirname(parent)) == os.path.normcase(str(codex_home() / 'worktrees')) and not os.listdir(parent):
            os.rmdir(parent)
    except OSError:
        pass

# ---------------------------------------------------------------- ledger


def session_dir(session=None):
    return RUNS / (session or SESSION)


def save(meta):
    folder = Path(meta['dir'])
    temporary = folder / ('meta.json.' + os.urandom(6).hex() + '.tmp')
    with open(temporary, 'w', encoding='utf-8') as handle:
        json.dump({key: value for key, value in meta.items() if key != 'dir'}, handle, ensure_ascii=False, indent=1)
    target = folder / 'meta.json'
    deadline = time.monotonic() + 1
    while True:
        try:
            os.replace(temporary, target)
            return
        except PermissionError as error:
            # A Windows reader can hold the old file open without sharing delete access.
            if getattr(error, 'winerror', None) not in (5, 32, 33) or time.monotonic() >= deadline:
                temporary.unlink(missing_ok=True)
                raise
            time.sleep(0.025)


def load_runs(session=None):
    folder = session_dir(session)
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    runs = []
    for name in names:
        run_dir = folder / name
        if not run_dir.is_dir():
            continue
        try:
            meta = json.loads((run_dir / 'meta.json').read_text(encoding='utf-8'))
            if not isinstance(meta, dict):
                raise ValueError
            meta['dir'] = str(run_dir)
        except (OSError, ValueError):
            # No ledger entry yet (a run that is just starting) or a broken folder: judge by age.
            try:
                created = run_dir.stat().st_mtime
            except OSError:
                created = 0
            meta = {'dir': str(run_dir), 'status': 'unknown', 'created': created}
        runs.append(meta)
    return sorted(runs, key=lambda run: run.get('created') or 0)


def sessions():
    try:
        return [name for name in os.listdir(RUNS) if ident(name) and (RUNS / name).is_dir()]
    except OSError:
        return []


def is_running(run):
    if run.get('status') == 'unknown':
        return time.time() - (run.get('created') or 0) < 600
    if run.get('status') != 'running':
        return False
    limit = ((run.get('timeoutMinutes') or 60) + 10) * 60
    return alive((run.get('runner') or {}).get('pid')) and time.time() - (run.get('created') or 0) < limit


@contextmanager
def admission_lock():
    RUNS.mkdir(parents=True, exist_ok=True)
    with open(RUNS / '.admission.lock', 'a+b') as lock:
        if WINDOWS:
            import msvcrt
            lock.seek(0)
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
            except OSError:
                fail('another runner is registering a run. Try again shortly.', 4)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX)
        yield  # closing releases the lock on both platforms


def all_running():
    return [run for session in sessions() for run in load_runs(session) if run.get('status') == 'running' and is_running(run)]


def find_run(thread):
    runs = [run for run in load_runs() if run.get('thread')]
    if thread == 'last':
        runs = [run for run in runs if run.get('mode') != 'review']
        return runs[-1] if runs else None
    matches = [run for run in reversed(runs) if run.get('thread') == thread]
    return next((run for run in matches if is_running(run)), matches[0] if matches else None)


def failure_reason(errors, tail):
    """A failure's kind for Pacer's statistics and alerts, never its text."""
    text = (' '.join(errors) + ' ' + ''.join(tail)).lower()
    if any(word in text for word in ('not logged in', 'login', 'unauthorized', '401', 'authentication')):
        return 'login'
    if any(word in text for word in ('usage limit', 'rate limit', '429', 'quota')):
        return 'quota'
    if 'model' in text and any(word in text for word in ('not found', 'unsupported', 'does not exist', 'not supported', 'invalid')):
        return 'model'
    return 'other'


def worktree_base(run):
    return run.get('appliedTree') or run.get('worktreeBase') or 'HEAD'


def worktree_changes(run):
    tree = run['worktree']
    tracked = git(tree, ['diff', '--name-status', worktree_base(run), '--'])
    untracked = git(tree, ['ls-files', '--others', '--exclude-standard'])
    if tracked is None or untracked is None:
        return None
    return [line.replace('\t', ' ') for line in tracked.splitlines()] + ['A ' + name for name in untracked.splitlines()]


def add_pending(threads):
    if not threads:
        return
    RUNS.mkdir(parents=True, exist_ok=True)
    with open(PENDING, 'a', encoding='utf-8') as handle:
        handle.write(''.join(thread + '\n' for thread in threads))


def retry_pending(codex):
    claimed = PENDING.with_name(PENDING.name + '.' + str(os.getpid()))
    try:
        os.replace(PENDING, claimed)
    except OSError:
        return
    try:
        threads = sorted(set(t for t in claimed.read_text(encoding='utf-8').split() if UUID.fullmatch(t)))
    finally:
        try:
            claimed.unlink()
        except OSError:
            pass
    add_pending(delete_threads(codex, threads))


def pending_worktree(run):
    """A worktree whose changes nobody applied or discarded yet."""
    if run.get('discarded') or (run.get('applied') and not run.get('appliedTree')):
        return False
    return bool(run.get('worktree')) and os.path.isdir(run['worktree']) and worktree_changes(run) != []


def worktree_patch(run):
    tree = run['worktree']
    if git(tree, ['add', '-A']) is None:
        return None, None
    staged = (git(tree, ['write-tree']) or '').strip()
    if not staged:
        return None, None
    result = run_quiet(['git', 'diff', '--binary', worktree_base(run), staged, '--'], cwd=tree, timeout=120)
    return staged, result.stdout if result is not None and result.returncode == 0 else None


def save_patch(run):
    """Keeps a worktree's unapplied changes as <root>/patches/<project>-<time>-<thread>.patch."""
    _, patch = worktree_patch(run)
    if not patch:
        return None
    name = '%s-%s-%s.patch' % (re.sub(r'[^A-Za-z0-9._-]+', '-', run.get('project') or 'project')[:40],
                               time.strftime('%Y%m%d-%H%M%S', time.localtime(run.get('created') or time.time())),
                               (run.get('thread') or 'run')[:8])
    try:
        PATCHES.mkdir(parents=True, exist_ok=True)
        path = PATCHES / name
        while True:
            try:
                with path.open('xb') as handle:
                    handle.write(patch)
                return path
            except FileExistsError:
                path = PATCHES / (name[:-6] + '-' + os.urandom(4).hex() + '.patch')
    except OSError:
        return None


def cleanup_in_progress(lock):
    try:
        owner = lock.read_text(encoding='ascii').strip()
        if owner.isdecimal():
            return alive(int(owner))
        return time.time() - lock.stat().st_mtime < 300  # earlier runners left an empty marker
    except FileNotFoundError:
        return False


def clean_session(session, codex, why, stopped_at=None):
    """Deletes the finished runs of one Claude session that its record setting
    lets go. `why`: `turn` (the turn ended), `now` (Claude asked for cleanup),
    `alive` or `gone` (a sweep, with the session's Claude process running or not).
    Running runs always stay."""
    folder = session_dir(session)
    if not folder.is_dir():
        return 0, 0
    lock = folder / '.cleanup.lock'
    # A resume either registers first or sees this marker until deletion finishes.
    with admission_lock():
        if cleanup_in_progress(lock):
            return 0, 0
        try:
            lock.unlink(missing_ok=True)
            with lock.open('x', encoding='ascii') as owner:
                owner.write(str(os.getpid()))
        except OSError:
            return 0, 0
    keep, hours = records(config()) if CONFIG.exists() else ('keep', 0)
    deleted = kept = 0
    try:
        runs = load_runs(session)
        groups = {}
        for run in runs:
            groups.setdefault(run.get('thread') or run['dir'], []).append(run)
        doomed, dropped = [], []
        for group in groups.values():
            latest = group[-1]
            later_turn = stopped_at is not None and (latest.get('created') or 0) > stopped_at
            if later_turn or any(is_running(run) for run in group):
                kept += len(group)
                continue
            expired = (latest.get('ended') or latest.get('created') or 0) + hours * 3600 <= time.time()
            delete = why == 'now' or (keep == 'turn' and why in ('turn', 'gone')) or (keep == 'timed' and expired)
            if why == 'gone' or delete:
                record_worktree(latest)
                if pending_worktree(latest) and (why != 'gone' or not save_patch(latest)):
                    kept += len(group)
                    continue
                remove_worktree(latest)
            if delete or (keep == 'keep' and why == 'gone'):
                (doomed if delete and CONFIG.exists() else dropped).extend(group)
            else:
                kept += len(group)
        threads = []
        for run in doomed:
            for thread in (run.get('childThreads') or []) + ([run['thread']] if run.get('thread') else []):
                if thread not in threads:
                    threads.append(thread)
        add_pending(delete_threads(codex, threads))
        for run in doomed + dropped:
            shutil.rmtree(run['dir'], ignore_errors=True)
            if os.path.exists(run['dir']):
                kept += 1
            else:
                deleted += 1
    finally:
        try:
            lock.unlink()
        except OSError:
            pass
        try:
            folder.rmdir()
        except OSError:
            pass
    return deleted, kept


def request_stop(run, by):
    # Pacer writes "pacer" here when the user stops a run from its task list.
    try:
        (Path(run['dir']) / 'stop').write_text(by, encoding='utf-8')
        return True
    except OSError:
        return False


def sweep(codex, current=None, from_stop=False):
    """Retries blocked deletions, deletes runs whose time is up, then cleans
    sessions whose Claude process is gone or that are older than two days.
    Stop-triggered sweeps leave running jobs alone. Run starts and explicit
    cleanup also stop orphaned jobs and jobs in sessions older than two days."""
    retry_pending(codex)
    for session in sessions():
        if session == current:
            continue
        runs = load_runs(session)
        if not runs:
            try:
                session_dir(session).rmdir()
            except OSError:
                pass
            continue
        newest = max(run.get('created') or 0 for run in runs)
        owners = [run.get('owner', {}).get('pid') for run in runs if isinstance(run.get('owner'), dict)]
        timed = records(config())[0] == 'timed'
        # An unrelated Stop is no evidence that a session without a PID has exited.
        recent = time.time() - newest < STALE
        if (any(alive(pid) for pid in owners) and (recent or from_stop)) or (from_stop and not any(owners) and recent):
            if timed:
                clean_session(session, codex, 'alive')
            continue
        if not from_stop:
            for run in runs:
                if is_running(run):
                    request_stop(run, 'sweep')
        clean_session(session, codex, 'gone')
    try:
        RUNS.rmdir()
    except OSError:
        pass

# ---------------------------------------------------------------- commands


def list_models(o):
    codex = resolve_codex() or fail('Codex not found. Install it (npm install -g @openai/codex) or set its path in Pacer.', 3)
    result = run_quiet(codex + ['debug', 'models'], timeout=120)
    if result is None or result.returncode != 0:
        fail('codex debug models failed', 1)
    try:
        catalog = json.loads(result.stdout.decode('utf-8', 'replace'))
    except ValueError:
        fail('could not read the model list', 1)
    models = catalog if isinstance(catalog, list) else catalog.get('models') or []
    defaults = config_defaults()
    listed = [model for model in models if isinstance(model, dict) and model.get('visibility') in (None, 'list')]
    if o.json:
        rows = [{'slug': model.get('slug'), 'name': model.get('display_name') or model.get('slug'),
                 'efforts': [level.get('effort') if isinstance(level, dict) else level for level in model.get('supported_reasoning_levels') or []],
                 'fast': bool(model.get('service_tiers'))} for model in listed]
        print(json.dumps({'defaults': defaults, 'models': rows}, ensure_ascii=False))
        return
    print('config defaults: model=%s effort=%s service_tier=%s' % (defaults.get('model', '(codex default)'),
          defaults.get('model_reasoning_effort', '(model default)'), defaults.get('service_tier', '(standard)')))
    for model in listed:
        efforts = '/'.join(str(level.get('effort') if isinstance(level, dict) else level) for level in model.get('supported_reasoning_levels') or [])
        fast = '; '.join('%s: %s' % (tier.get('name'), tier.get('description')) for tier in model.get('service_tiers') or [] if isinstance(tier, dict)) or 'no fast tier'
        print('%s | efforts %s (default %s) | %s' % (model.get('slug'), efforts, model.get('default_reasoning_level'), fast))


def doctor():
    """Pacer's self-check: everything a run needs, without calling a model.
    Prints one JSON object."""
    codex = resolve_codex()
    version = login = None
    if codex:
        result = run_quiet(codex + ['--version'], timeout=30)
        if result is not None and result.returncode == 0:
            version = (result.stdout.decode('utf-8', 'replace').strip().split() or [None])[-1]
        result = run_quiet(codex + ['login', 'status'], timeout=30)
        login = 'unknown' if result is None else 'ok' if result.returncode == 0 else 'missing'
    try:
        RUNS.mkdir(parents=True, exist_ok=True)
        probe = RUNS / ('.probe-' + os.urandom(4).hex())
        probe.write_text('ok', encoding='utf-8'); probe.unlink()
        ledger = True
    except OSError:
        ledger = False
    finally:
        try:
            RUNS.rmdir()
        except OSError:
            pass
    skill = ROOT.parent / 'plugin' / 'pacer' / 'skills' / 'codex' / 'SKILL.md'
    print(json.dumps({'codex': {'found': bool(codex), 'path': codex[0] if codex else None, 'version': version}, 'login': login,
                      'ledger': ledger, 'skill': skill.is_file(), 'config': CONFIG.is_file(), 'pending': pending_count(),
                      'python': '%d.%d.%d' % sys.version_info[:3]}, ensure_ascii=False))


def pending_count():
    try:
        return len(set(PENDING.read_text(encoding='utf-8').split()))
    except OSError:
        return 0


def list_runs():
    runs = load_runs()
    pending = pending_count()
    if pending:
        print('%d Codex thread(s) queued for deletion (held by another Codex process; retried at every cleanup)' % pending)
    if not runs:
        print('no Codex runs in this Claude session')
        return
    for run in runs:
        state = run.get('status', '?')
        pid = (run.get('runner') or {}).get('pid')
        if state == 'running' and pid and not alive(pid):
            state = 'stopped'
        elif state == 'unknown' and is_running(run):
            state = 'running'
        tree = ''
        if run.get('worktree'):
            tree = ' · worktree %s%s' % (run['worktree'], ' (applied)' if run.get('applied') else ' (discarded)' if run.get('discarded') else '')
        print('%s · %s · %s · %s/%s%s' % (run.get('thread') or '?', run.get('mode') or '?', state, run.get('model') or '?', run.get('effort') or '?', tree))


def stop_run(thread):
    run = find_run(thread)
    if not run:
        fail('no run with thread %s in this Claude session' % thread)
    if not is_running(run):
        print('that run has already finished')
        return
    request_stop(run, 'claude')
    print('stopping %s; its runner reports "stopped" in a moment' % thread)


def apply_run(thread):
    run = find_run(thread)
    if run and is_running(run):
        fail('that run is still in progress')
    if run:
        record_worktree(run)
    if not run or not run.get('worktree'):
        fail('no worktree run with thread %s in this Claude session' % thread)
    tree = run['worktree']
    if not os.path.isdir(tree):
        fail('worktree is gone: ' + tree, 1)
    staged, patch = worktree_patch(run)
    if patch is None:
        fail("could not read the worktree's changes", 1)
    if patch:
        path = Path(run['dir']) / 'worktree.patch'
        path.write_bytes(patch)
        root = toplevel(run['cwd'])
        if not root:
            fail('could not locate the original repository', 1)
        applied = run_quiet(['git', 'apply', '--whitespace=nowarn', str(path)], cwd=root, timeout=120)
        if applied is None or applied.returncode != 0:
            detail = applied.stdout.decode('utf-8', 'replace').strip() if applied is not None else ''
            fail('git apply failed in %s:\n%s\npatch kept in the run folder: %s' % (root, detail, path), 1)
        files = (git(tree, ['diff', '--name-status', worktree_base(run), staged, '--']) or '').replace('\t', ' ').splitlines()
        print('applied %d file(s) to %s: %s' % (len(files), root, ', '.join(files)))
    else:
        print('nothing to apply: the worktree has no changes')
    run.update(applied=True, appliedTree=staged, worktreeChanges=0)
    save(run)


def discard_run(thread):
    run = find_run(thread)
    if not run:
        fail('no run with thread %s in this Claude session' % thread)
    run['discarded'] = True; save(run)
    print('discarded: %s%s; deleted at the next cleanup' % (thread, ' (worktree %s)' % run['worktree'] if run.get('worktree') else ''))


def stop_decision(value, errors, session):
    # Match Stop error attachments by tool-use ID, as in claude_activity.py.
    if not isinstance(value, dict):
        return False
    attachment = value.get('attachment')
    if value.get('type') == 'attachment' and isinstance(attachment, dict) and attachment.get('hookEvent') == 'Stop':
        kind = attachment.get('type')
        if kind in ('hook_blocking_error', 'hook_non_blocking_error'):
            stop = ident(attachment.get('toolUseID'))
            if not stop:
                return False
            blocked, failures = errors.get(stop, (False, 0))
            errors[stop] = (blocked or kind == 'hook_blocking_error', failures + 1)
            if len(errors) > 16:
                return False
    if value.get('type') == 'system' and value.get('subtype') == 'stop_hook_summary':
        blocked, failures = errors.get(ident(value.get('toolUseID')), (False, 0))
        listed = value.get('hookErrors')
        return (value.get('sessionId', session) == session and not blocked and value.get('preventedContinuation') is False
                and value.get('hookAdditionalContext') == [] and isinstance(listed, list) and len(listed) <= failures)
    return None


def confirmed_stop(path, cursor, session, timeout=16 * 60):
    """Read only new transcript lines, through the first Stop summary."""
    import hashlib
    if not path or not isinstance(cursor, dict) or not isinstance(cursor.get('at'), (int, float)):
        return False
    offset = cursor.get('offset')
    if not isinstance(offset, int) or offset < 0:
        return False
    identity = (cursor.get('dev'), cursor.get('ino'))
    tail = cursor.get('tail')
    errors = {}
    size = offset
    deadline = time.monotonic() + timeout
    delay = 1
    try:
        while time.monotonic() < deadline:
            info = os.stat(path)
            if (info.st_dev, info.st_ino) != identity or info.st_size < size:
                return False
            if info.st_size > size:
                size = info.st_size
                with open(path, 'rb') as handle:
                    if not os.path.samestat(info, os.fstat(handle.fileno())):
                        return False
                    # A truncate and rewrite can grow past the old offset between polls.
                    handle.seek(max(0, offset - 64))
                    if hashlib.sha256(handle.read(min(offset, 64))).hexdigest() != tail:
                        return False
                    while offset < size:
                        line = handle.readline(min(size - offset, 1024 * 1024 + 1))
                        if len(line) > 1024 * 1024 or time.monotonic() >= deadline:
                            return False
                        if not line.endswith(b'\n'):
                            break
                        offset += len(line)
                        decision = stop_decision(json.loads(line), errors, session)
                        if decision is not None:
                            current = os.stat(path)
                            return decision and os.path.samestat(info, current) and current.st_size >= size
                    handle.seek(max(0, offset - 64))
                    tail = hashlib.sha256(handle.read(min(offset, 64))).hexdigest()
            time.sleep(min(delay, max(0, deadline - time.monotonic())))
            delay = min(2, delay + 0.5)
    except (OSError, ValueError):
        pass
    return False


def cleanup_now(session):
    codex = resolve_codex()
    deleted, kept = clean_session(session, codex, 'now')
    sweep(codex, current=session)
    pending = pending_count()
    print('deleted %d run(s)%s%s' % (deleted, '; kept %d still in progress' % kept if kept else '',
          '; %d thread(s) still queued for deletion (held by another Codex process)' % pending if pending else ''))


class Events:
    def __init__(self):
        self.thread = None; self.usage = None; self.commands = 0; self.errors = []; self.warnings = []; self.changes = {}

    def handle(self, line):
        line = line.strip()
        if not line:
            return None
        try:
            event = json.loads(line)
        except ValueError:
            return None
        kind = event.get('type') if isinstance(event, dict) else None
        if kind == 'thread.started':
            return event.get('thread_id')
        if kind == 'turn.completed':
            self.usage = event.get('usage') or self.usage
        elif kind == 'turn.failed':
            error = event.get('error') or {}
            self.errors.append(error.get('message') if isinstance(error, dict) and error.get('message') else 'turn failed')
        elif kind == 'error':
            self.warnings.append(event.get('message') or 'error')
        elif kind == 'item.completed':
            item = event.get('item') or {}
            if item.get('type') == 'command_execution':
                self.commands += 1
            if item.get('type') == 'file_change':
                for change in item.get('changes') or []:
                    if isinstance(change, dict) and change.get('path'):
                        self.changes[change['path']] = {'add': 'A', 'delete': 'D', 'update': 'M'}.get(change.get('kind'), change.get('kind') or '?')
        return None


def quota_left():
    """The least Codex quota left in any window, in percent, from the snapshot
    Pacer writes; None when it is missing or older than ten minutes."""
    try:
        value = json.loads(QUOTA.read_text(encoding='utf-8'))
        left, at = value.get('remainingPercent'), value.get('at')
        if isinstance(left, (int, float)) and isinstance(at, (int, float)) and 0 <= time.time() - at < 600:
            return float(left)
    except (OSError, ValueError, AttributeError):
        pass
    return None


def run_job(o):
    prompt = read_prompt(o).strip()
    if o.mode != 'review' and not prompt:
        fail('no prompt: pass -f <brief-file> or prompt text')
    if not CONFIG.exists():
        fail('Codex for Claude is turned off in Pacer (Settings → Collaboration).', 3)
    standing = instructions(config())
    if standing:
        prompt = (prompt + '\n\n' if prompt else '') + 'Standing instructions from the user (set in Codex Pacer):\n' + standing
    if o.mode == 'review' and prompt:
        scope = 'Review staged, unstaged and untracked changes.'
        if o.review[0] == '--base':
            scope = 'Review the changes against base branch %s (merge-base diff).' % o.review[1]
        elif o.review[0] == '--commit':
            scope = 'Review the changes introduced by commit %s.' % o.review[1]
        if o.title:
            scope += '\nReview title: ' + o.title
        prompt = scope + '\n\n' + prompt
    codex = resolve_codex() or fail('Codex not found. Install it (npm install -g @openai/codex) or set its path in Pacer.', 3)
    if not o.dry_run and records(config())[0] == 'timed':
        clean_session(SESSION, codex, 'alive')
    resume_id = None
    origin = None
    if o.mode == 'resume':
        origin = find_run(o.target)
        if not origin:
            fail('thread %s was not started in this Claude session (threads are deleted when a turn ends; start a fresh run with the earlier result in the brief)' % o.target)
        if is_running(origin):
            fail('that thread is still running; wait for it to finish')
        record_worktree(origin, persist=False)  # the resumed run records the path at admission
        resume_id = origin.get('thread')
    cwd = os.path.abspath(o.cd or (origin or {}).get('worktree') or (origin or {}).get('cwd') or os.getcwd())
    # Outside a git repository a task runs in place; reviews and explicit worktrees need one.
    repo = toplevel(cwd)
    in_place = None
    if not repo:
        if o.mode == 'review':
            fail('review needs a git repository and %s is not one; pass -C <repository>, or run a task that names the files instead.' % cwd)
        if o.worktree and not o.worktree_setting:
            fail('--worktree needs a git repository and %s is not one; run without --worktree.' % cwd)
        if o.worktree:
            o.worktree = False
            in_place = 'not a git repository, so Codex worked in place'
    run_dir = session_dir() / (time.strftime('%Y%m%d-%H%M%S') + '-' + o.mode + '-' + str(os.getpid()))
    last_file = str(run_dir / 'last.md')
    args = codex_args(o, last_file, bool(prompt), resume_id)
    if o.dry_run:
        print(json.dumps({'cwd': cwd, 'runDir': str(run_dir), 'command': codex + args, 'promptChars': len(prompt)}, ensure_ascii=False, indent=2))
        return 0

    settings = config()
    limit = settings.get('maxConcurrent')
    limit = limit if isinstance(limit, int) and not isinstance(limit, bool) and limit > 0 else 3

    def refuse(reason, message):
        fail(message, 4)
    floor = settings.get('quotaFloor')
    left = quota_left() if floor in (10, 20) else None
    if left is not None and left < floor:
        refuse('quota', 'Codex has %d%% of its quota left, below the %d%% the user set in Pacer (Settings → Collaboration). '
               'Tell the user; this run did not start.' % (left, floor))
    sweep(codex, current=SESSION)
    stop_requested = False

    def stop_from_claude(*_):
        nonlocal stop_requested
        stop_requested = True

    for sig in (signal.SIGTERM, getattr(signal, 'SIGHUP', None), getattr(signal, 'SIGBREAK', None)):
        if sig is not None:
            signal.signal(sig, stop_from_claude)
    base = (origin or {}).get('worktreeBase')
    if o.worktree:
        base = (git(cwd, ['rev-parse', 'HEAD']) or '').strip() or None
    meta = {
        'v': 1, 'dir': str(run_dir), 'session': SESSION, 'owner': {'pid': OWNER}, 'runner': {'pid': os.getpid()},
        'status': 'running', 'mode': o.mode, 'label': o.label, 'created': round(time.time(), 3), 'timeoutMinutes': o.timeout,
        'thread': resume_id, 'owned': o.mode != 'resume', 'childThreads': [], 'cwd': (origin or {}).get('cwd') or cwd,
        'root': (repo or cwd) if o.write and not o.worktree else None, 'write': bool(o.write), 'worktree': (origin or {}).get('worktree'),
        'model': o.model, 'effort': o.effort, 'fast': o.fast, 'applied': False, 'discarded': False, 'warned': False,
        'project': os.path.basename(os.path.normpath(repo or cwd))[:80],
        'worktreeBase': base, 'appliedTree': (origin or {}).get('appliedTree'),
    }
    meta['worktreeRequested'] = o.worktree or bool((origin or {}).get('worktreeRequested') or base)
    if meta['worktreeRequested']:
        meta['codexHome'] = str(codex_home().absolute())
    with admission_lock():
        if resume_id:
            if cleanup_in_progress(session_dir() / '.cleanup.lock'):
                fail('this session is being cleaned up. Try again shortly.', 4)
            if not (Path(origin['dir']) / 'meta.json').is_file():
                fail('that run was cleaned up before it could resume')
        running = all_running()
        if resume_id and any(run.get('thread') == resume_id for run in running):
            fail('that thread is still running; wait for it to finish')
        if len(running) >= limit:
            refuse('concurrency', '%d Codex run(s) are already running, the most Pacer allows at once (Settings → Collaboration). '
                   'Wait for one to finish, then run this again.' % len(running))
        if o.write and not o.worktree and not (origin or {}).get('worktree'):
            # One writer per repository, or per folder outside one.
            root = repo or cwd
            for run in running:
                if run.get('write') and not run.get('worktree') and run.get('root') and os.path.normcase(run['root']) == os.path.normcase(root):
                    refuse('writer', 'another Codex run (thread %s) is already changing files in %s. Wait for it to finish%s.'
                           % (run.get('thread') or '?', root, ', or run this one with --worktree so its changes stay apart' if repo else ''))

        run_dir.mkdir(parents=True, exist_ok=True)
        save(meta)
    before = snapshot(cwd) if o.write and not o.worktree and not (origin or {}).get('worktree') else None
    events = Events()
    environment = dict(os.environ)
    environment['CODEX_INTERNAL_ORIGINATOR_OVERRIDE'] = ORIGINATOR
    options = {'cwd': cwd, 'stdin': subprocess.PIPE if prompt else subprocess.DEVNULL, 'stdout': subprocess.PIPE,
               'stderr': subprocess.PIPE, 'env': environment}
    if WINDOWS:
        options['creationflags'] = NO_WINDOW
    else:
        options['start_new_session'] = True
    started = time.time()
    try:
        child = subprocess.Popen(codex + args, **options)
    except OSError as error:
        meta.update(status='failed', ended=round(time.time(), 3), seconds=0)
        save(meta)
        fail('could not start Codex: ' + str(error), 1)
    job = bind_to_runner(child)
    meta['codex'] = {'pid': child.pid}
    save(meta)
    if prompt:
        def feed():
            try:
                child.stdin.write(prompt.encode('utf-8'))
                child.stdin.close()
            except OSError:
                pass
        threading.Thread(target=feed, daemon=True).start()
    tail = []
    meta_lock = threading.Lock()

    def read_errors():
        with open(run_dir / 'stderr.log', 'wb') as log:
            for chunk in iter(lambda: child.stderr.readline(), b''):
                log.write(chunk)
                tail.append(chunk.decode('utf-8', 'replace'))
                del tail[:-200]

    def read_events():
        with open(run_dir / 'events.jsonl', 'wb') as log:
            for chunk in iter(lambda: child.stdout.readline(), b''):
                log.write(chunk)
                thread = events.handle(chunk.decode('utf-8', 'replace'))
                if thread and not meta.get('thread'):
                    with meta_lock:
                        meta['thread'] = thread
                        save(meta)  # at once, so cleanup finds the thread even if this process dies
    readers = [threading.Thread(target=read_errors, daemon=True), threading.Thread(target=read_events, daemon=True)]
    for reader in readers:
        reader.start()
    timed_out = stopped = False
    deadline = started + o.timeout * 60
    stop_file = run_dir / 'stop'
    next_lookup = 0
    try:
        while child.poll() is None:
            if stop_requested or stop_file.exists():
                stopped = True
                kill_tree(child)
                break
            if time.time() > deadline:
                timed_out = True
                kill_tree(child)
                break
            # The thread's folder is set when it starts: once the rollout names it, stop reading the rollout.
            if meta['worktreeRequested'] and not meta['worktree'] and meta['thread'] and next_lookup is not None and time.monotonic() >= next_lookup:
                with meta_lock:
                    known = record_worktree(meta)
                next_lookup = None if known else time.monotonic() + 3
            time.sleep(0.25)
    except KeyboardInterrupt:
        stopped = True
        kill_tree(child)
    exit_code = child.wait()
    for reader in readers:
        reader.join(5)
    del job

    seconds = time.time() - started
    index = rollout_index()
    context = turn_context(index.get(meta.get('thread'))) or {}
    defaults = config_defaults()
    stopped = stopped or stop_requested
    ok = exit_code == 0 and not timed_out and not stopped and not events.errors
    fast = ('config (%s)' % defaults.get('service_tier', 'standard')) if o.fast is None else ('on' if o.fast else 'off')
    model = context.get('model') or o.model or defaults.get('model') or '?'
    effort = context.get('effort') or o.effort or defaults.get('model_reasoning_effort') or 'model default'
    sandbox = {'read-only': 'read-only', 'workspace-write': 'workspace-write', 'workspace-write-network': 'workspace-write + network',
               'danger-full-access': 'full access'}[o.level]
    try:
        final = Path(last_file).read_text(encoding='utf-8').strip()
    except OSError:
        final = ''
    changed = None
    with meta_lock:
        record_worktree(meta, context)
    if meta.get('worktree'):
        changed = worktree_changes(meta)
        with meta_lock:
            meta['worktreeChanges'] = len(changed) if changed is not None else None
    elif before:
        after = snapshot(cwd)
        if after:
            changed = changed_between(before, after)
    if changed is None:
        changed = []
        for name, kind in events.changes.items():
            changed.append(kind + ' ' + change_path(name, cwd))
    status = 'ok' if ok else 'stopped' if stopped else 'timedOut' if timed_out else 'failed'
    try:
        by = stop_file.read_text(encoding='utf-8').strip()
    except OSError:
        by = ''
    reason = None if ok else 'stopped' if stopped else 'timeout' if timed_out else failure_reason(events.errors, tail)
    with meta_lock:
        meta.update(status=status, exitCode=exit_code, seconds=round(seconds, 1), ended=round(time.time(), 3), model=model, effort=effort,
                    fast=o.fast if o.fast is not None else (defaults.get('service_tier') == FAST_TIER if 'service_tier' in defaults else None),
                    usage=events.usage, commands=events.commands, changedFiles=len(changed), reason=reason,
                    stoppedBy=(by if by in ('pacer', 'claude', 'sweep') else 'claude') if stopped else None,
                    childThreads=sorted(child_threads(meta['thread'], index)) if meta.get('thread') else [])
        save(meta)

    run = runner_command()
    reason = {'pacer': 'stopped by the user in Pacer', 'claude': 'stopped', 'sweep': 'stopped because its Claude session ended'}
    label = {'ok': 'ok', 'stopped': reason.get(by, 'stopped'),
             'timedOut': 'timed out after %g min' % o.timeout, 'failed': 'failed (exit %s)' % exit_code}[status]
    print('codex %s · %.1fs · model %s · effort %s · fast %s · sandbox %s' % (label, seconds, model, effort, fast, sandbox))
    usage = events.usage or {}
    tokens = ' · tokens in %s (cached %s) out %s' % (usage.get('input_tokens', '?'), usage.get('cached_input_tokens', 0), usage.get('output_tokens', '?')) \
        if usage.get('input_tokens') or usage.get('output_tokens') else ''
    print('thread %s%s · commands %d' % (meta.get('thread') or '?', tokens, events.commands))
    if o.worktree or (origin or {}).get('worktree'):
        print('worktree: %s' % (meta.get('worktree') or "(not found; check Codex's message)"))
    elif in_place:
        print('worktree: none (%s)' % in_place)
    if o.write or meta.get('worktree'):
        print('changed files (%d): %s' % (len(changed), ', '.join(changed)) if changed else 'changed files: none')
    keep, hours = records(settings)
    print('output: %s (%s)' % (run_dir, {'turn': 'deleted with the thread when this Claude turn ends',
                                         'timed': 'deleted with the thread %d h after the run' % hours,
                                         'keep': 'the thread stays in Codex history'}[keep]))
    if meta.get('thread'):
        print('follow up: %s resume %s -f - <<\'EOF\' … EOF' % (run, meta['thread']))
    for error in events.errors:
        print('error: ' + error)
    warnings = list(dict.fromkeys(events.warnings))
    for warning in warnings[:3]:
        print('warning: ' + warning)
    if len(warnings) > 3:
        print('warning: … %d more in events.jsonl' % (len(warnings) - 3))
    # MCP servers from the user's config that aren't running flood stderr; keep them in stderr.log only.
    lines = [line.rstrip() for line in ''.join(tail).splitlines() if line.strip() and 'rmcp::transport' not in line]
    if not ok and not stopped and lines:
        print('----- stderr (tail) -----')
        print('\n'.join(lines[-25:]))
    print('----- Codex final message -----')
    if not final:
        print('(none)')
    elif len(final) > MAX_PRINT:
        print(final[:MAX_PRINT] + '\n… truncated; full text in ' + last_file)
    else:
        print(final)
    return 0 if ok else 130 if stopped else 124 if timed_out else 1


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except (AttributeError, ValueError):
            pass
    home = config().get('codexHome')
    if home:
        os.environ['CODEX_HOME'] = home
    o = parse(sys.argv[1:])
    if o.mode == 'models':
        list_models(o)
    elif o.mode == 'runs':
        list_runs()
    elif o.mode == 'stop':
        stop_run(o.target)
    elif o.mode == 'apply':
        apply_run(o.target)
    elif o.mode == 'discard':
        discard_run(o.target)
    elif o.mode == 'cleanup':
        cleanup_now(SESSION)
    elif o.mode == 'turn-end':
        if o.session and CONFIG.is_file() and records(config())[0] != 'keep':
            if confirmed_stop(o.transcript, o.cursor, o.session):
                clean_session(o.session, resolve_codex(), 'turn', stopped_at=o.cursor['at'])
    elif o.mode == 'sweep':
        sweep(resolve_codex(), current=o.session, from_stop=o.session is not None)
    elif o.mode == 'doctor':
        doctor()
    else:
        sys.exit(run_job(o))


if __name__ == '__main__':
    main()
