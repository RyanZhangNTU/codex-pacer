"""Windows filesystem adapter for Pacer's unchanged shared Claude program."""
import base64, ctypes, hashlib, msvcrt, os, pathlib, sys, types
from ctypes import wintypes as w

kernel = ctypes.WinDLL('kernel32', use_last_error=True)
security = ctypes.WinDLL('advapi32', use_last_error=True)

def api(library, name, result, *arguments):
    function = getattr(library, name)
    function.restype = result
    function.argtypes = arguments
    return function

close = api(kernel, 'CloseHandle', w.BOOL, w.HANDLE)
current_process = api(kernel, 'GetCurrentProcess', w.HANDLE)
open_token = api(security, 'OpenProcessToken', w.BOOL, w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE))
duplicate_token = api(security, 'DuplicateToken', w.BOOL, w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE))
check_membership = api(security, 'CheckTokenMembership', w.BOOL, w.HANDLE, w.LPVOID, ctypes.POINTER(w.BOOL))
well_known_sid = api(security, 'CreateWellKnownSid', w.BOOL, w.DWORD, w.LPVOID, w.LPVOID, ctypes.POINTER(w.DWORD))
token_information = api(security, 'GetTokenInformation', w.BOOL, w.HANDLE, w.DWORD, w.LPVOID, w.DWORD, ctypes.POINTER(w.DWORD))
get_security = api(security, 'GetSecurityInfo', w.DWORD, w.HANDLE, w.DWORD, w.DWORD,
                   ctypes.POINTER(w.LPVOID), w.LPVOID, w.LPVOID, w.LPVOID, ctypes.POINTER(w.LPVOID))
equal_sid = api(security, 'EqualSid', w.BOOL, w.LPVOID, w.LPVOID)
sid_length = api(security, 'GetLengthSid', w.DWORD, w.LPVOID)
local_free = api(kernel, 'LocalFree', w.HANDLE, w.HANDLE)
create_file = api(kernel, 'CreateFileW', w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
attributes = api(kernel, 'GetFileAttributesW', w.DWORD, w.LPCWSTR)
file_type = api(kernel, 'GetFileType', w.DWORD, w.HANDLE)
create_mutex = api(kernel, 'CreateMutexW', w.HANDLE, w.LPVOID, w.BOOL, w.LPCWSTR)
wait = api(kernel, 'WaitForSingleObject', w.DWORD, w.HANDLE, w.DWORD)
release_mutex = api(kernel, 'ReleaseMutex', w.BOOL, w.HANDLE)

class FileInformation(ctypes.Structure):
    _fields_ = [('attributes', w.DWORD), ('created', w.FILETIME), ('accessed', w.FILETIME),
                ('modified', w.FILETIME), ('volume', w.DWORD), ('size_high', w.DWORD),
                ('size_low', w.DWORD), ('links', w.DWORD), ('index_high', w.DWORD), ('index_low', w.DWORD)]

file_information = api(kernel, 'GetFileInformationByHandle', w.BOOL, w.HANDLE, ctypes.POINTER(FileInformation))
owners = []
administrator_sid = ctypes.create_string_buffer(68)  # SECURITY_MAX_SID_SIZE
elevated = False
administrators_enabled = False
held_mutexes = []

def renderer_arguments(command):
    # Claude uses Git Bash when available, and PowerShell otherwise. shell=True
    # would select COMSPEC/cmd instead, changing the user's renderer language.
    configured = os.environ.get('CLAUDE_CODE_GIT_BASH_PATH')
    candidates = [pathlib.Path(configured)] if configured else [
        pathlib.Path(os.environ.get(name, 'C:/Program Files'))/'Git/bin/bash.exe'
        for name in ('ProgramFiles', 'ProgramFiles(x86)')]
    if not configured and os.environ.get('LOCALAPPDATA'):
        candidates.append(pathlib.Path(os.environ['LOCALAPPDATA'])/'Programs/Git/bin/bash.exe')
    for candidate in candidates:
        if candidate.is_absolute() and candidate.is_file():
            return [str(candidate), '-c', command]
    directory = api(kernel, 'GetSystemDirectoryW', w.UINT, w.LPWSTR, w.UINT)
    buffer = ctypes.create_unicode_buffer(32768)
    length = directory(buffer, len(buffer))
    if not 0 < length < len(buffer):
        raise OSError('system shell unavailable')
    powershell = pathlib.Path(buffer.value)/'WindowsPowerShell/v1.0/powershell.exe'
    return [str(powershell), '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command]

def current_owners():
    global elevated, administrators_enabled
    owners.clear()
    token = w.HANDLE()
    if not open_token(current_process(), 8 | 2, ctypes.byref(token)):
        raise OSError('token unavailable')
    try:
        for kind in (1, 4):  # Keep TokenOwner only for fixed diagnostic facts.
            length = w.DWORD()
            token_information(token, kind, None, 0, ctypes.byref(length))
            if not 0 < length.value <= 65536:
                raise OSError('token unavailable')
            buffer = ctypes.create_string_buffer(length.value)
            if not token_information(token, kind, buffer, length, ctypes.byref(length)):
                raise OSError('token unavailable')
            owners.append((buffer, ctypes.cast(buffer, ctypes.POINTER(w.LPVOID))[0]))
        size = w.DWORD(len(administrator_sid))
        if not well_known_sid(26, None, administrator_sid, ctypes.byref(size)):  # WinBuiltinAdministratorsSid
            raise OSError('administrator SID unavailable')
        elevation, length = w.DWORD(), w.DWORD()
        if not token_information(token, 20, ctypes.byref(elevation), ctypes.sizeof(elevation), ctypes.byref(length)):
            raise OSError('elevation unavailable')
        elevated = bool(elevation.value)
        membership, enabled = w.HANDLE(), w.BOOL()
        if not duplicate_token(token, 1, ctypes.byref(membership)):  # SecurityIdentification
            raise OSError('membership unavailable')
        try:
            if not check_membership(membership, administrator_sid, ctypes.byref(enabled)):
                raise OSError('membership unavailable')
            administrators_enabled = bool(enabled.value)
        finally:
            close(membership)
    finally:
        close(token)

def native(path):
    path = pathlib.Path(path)
    if not path.is_absolute() or len(path.drive) != 2 or path.drive[1] != ':':
        raise OSError('unsafe path')
    return '\\\\?\\' + str(path)

def check_parents(path):
    for parent in pathlib.Path(path).parents:
        value = attributes(native(parent))
        if value == 0xffffffff:
            if ctypes.get_last_error() not in (2, 3):
                raise OSError('unsafe parent')
        elif value & 0x400:
            raise OSError('unsafe parent')

def owner_allowed(is_user, is_administrators, is_elevated, administrators_are_enabled):
    return is_user or is_administrators and is_elevated and administrators_are_enabled

def own_file(handle):
    owner = w.LPVOID()
    descriptor = w.LPVOID()
    if get_security(handle, 1, 1, ctypes.byref(owner), None, None, None, ctypes.byref(descriptor)) != 0:
        raise OSError('owner unavailable')
    try:
        if not owner_allowed(bool(equal_sid(owner, owners[0][1])),
                             bool(equal_sid(owner, administrator_sid)), elevated, administrators_enabled):
            raise OSError('foreign owner')
    finally:
        if descriptor:
            local_free(descriptor)

def private_open(path, flags):
    check_parents(path)
    # READ_CONTROL checks the owner; FILE_READ_ATTRIBUTES is also required for
    # the handle metadata check, including handles opened only for writing.
    access = 0x20080 | (0x40000000 if flags & (os.O_WRONLY | os.O_RDWR) else 0)
    if not flags & os.O_WRONLY:
        access |= 0x80000000
    creation = 1 if flags & os.O_EXCL else 4 if flags & os.O_CREAT else 3
    handle = create_file(native(path), access, 7, None, creation, 0x200000, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise OSError('file unavailable')
    try:
        info = FileInformation()
        if not file_information(handle, ctypes.byref(info)) or info.attributes & 0x410 or info.links != 1 or file_type(handle) != 1:
            raise OSError('unsafe file')
        own_file(handle)
        fd = msvcrt.open_osfhandle(handle, (flags & (os.O_WRONLY | os.O_RDWR | os.O_APPEND)) | os.O_BINARY | os.O_NOINHERIT)
        handle = None  # CRT now owns it.
        try:
            if flags & os.O_TRUNC:
                os.ftruncate(fd, 0)  # Only after owner/reparse checks.
            return fd
        except BaseException:
            os.close(fd)
            raise
    finally:
        if handle is not None:
            close(handle)

def flock(fd, kind):
    if kind != 2:
        raise OSError('unsupported lock')
    info = FileInformation()
    if not file_information(msvcrt.get_osfhandle(fd), ctypes.byref(info)):
        raise OSError('lock unavailable')
    # Global mutexes coordinate the same current-user file across login
    # sessions. The bounded kernel wait consumes no polling CPU.
    identity = (str(info.volume) + ':' + str(info.index_high) + ':' + str(info.index_low)).encode()
    identity += ctypes.string_at(owners[0][1], sid_length(owners[0][1]))
    handle = create_mutex(None, False, 'Global\\CodexPacer.ClaudeHook.v1.' + hashlib.sha256(identity).hexdigest())
    if not handle:
        raise OSError('lock unavailable')
    result = wait(handle, 2000)
    if result not in (0, 0x80):
        close(handle)
        raise OSError('lock timeout')
    held_mutexes.append(handle)

def run():
    current_owners()
    fcntl = types.ModuleType('fcntl')
    fcntl.LOCK_EX = 2
    fcntl.flock = flock
    sys.modules['fcntl'] = fcntl
    namespace = {'__name__': 'pacer_shared_claude'}
    exec(compile(base64.b64decode(SHARED_SOURCE), '<pacer-shared-claude>', 'exec'), namespace)
    namespace['private_open'] = private_open
    if len(sys.argv) > 1 and sys.argv[1] == 'statusline':
        # This process handles one invocation. Leave the shared cache/privacy
        # code intact and adapt only its subprocess shell selection.
        import subprocess
        original_run = subprocess.run
        def windows_renderer(arguments, *positional, **options):
            if options.get('shell') and isinstance(arguments, str):
                arguments = renderer_arguments(arguments)
                options['shell'] = False
            return original_run(arguments, *positional, **options)
        subprocess.run = windows_renderer
        try:
            namespace['main']()
        finally:
            subprocess.run = original_run
    else:
        namespace['main']()

if __name__ == '__main__':
    try:
        run()
    except (OSError, ValueError, ImportError):
        pass
    finally:
        for handle in reversed(held_mutexes):
            release_mutex(handle)
            close(handle)
