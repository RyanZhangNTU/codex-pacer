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
held_mutexes = []

def current_owners():
    token = w.HANDLE()
    if not open_token(current_process(), 8, ctypes.byref(token)):
        raise OSError('token unavailable')
    try:
        for kind in (1, 4):  # TokenUser and TokenOwner, matching the host adapter.
            length = w.DWORD()
            token_information(token, kind, None, 0, ctypes.byref(length))
            if not 0 < length.value <= 65536:
                raise OSError('token unavailable')
            buffer = ctypes.create_string_buffer(length.value)
            if not token_information(token, kind, buffer, length, ctypes.byref(length)):
                raise OSError('token unavailable')
            owners.append((buffer, ctypes.cast(buffer, ctypes.POINTER(w.LPVOID))[0]))
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

def own_file(handle):
    owner = w.LPVOID()
    descriptor = w.LPVOID()
    if get_security(handle, 1, 1, ctypes.byref(owner), None, None, None, ctypes.byref(descriptor)) != 0:
        raise OSError('owner unavailable')
    try:
        if not any(equal_sid(owner, sid) for _, sid in owners):
            raise OSError('foreign owner')
    finally:
        if descriptor:
            local_free(descriptor)

def private_open(path, flags):
    check_parents(path)
    access = 0x20000 | (0x40000000 if flags & (os.O_WRONLY | os.O_RDWR) else 0)
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
