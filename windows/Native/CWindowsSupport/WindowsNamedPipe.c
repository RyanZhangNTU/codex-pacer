#include "CWindowsSupport.h"
#if defined(_WIN32)
#include <windows.h>
#include <appmodel.h>
#include <wchar.h>
#include "WindowsProcessInternal.h"

typedef struct {
    HANDLE file, stopped, read_event, write_event;
    SRWLOCK read_lock, write_lock;
    volatile LONG cancelled;
    pacer_process_identity peer;
} PacerPipe;
static int pacer_pipe_peer(HANDLE pipe, LPCWSTR root, LPCWSTR family, pacer_process_identity *identity) {
    ULONG pid = 0;
    if (!GetNamedPipeServerProcessId(pipe, &pid)) return 0;
    HANDLE process = pacer_open_user_process(pid, PROCESS_QUERY_LIMITED_INFORMATION, 0);
    if (process == NULL) return 0;
    int matched = 0;
    WCHAR executable[32768]; DWORD length = 32768;
    size_t root_length = 0;
    while (root_length < 32767 && root[root_length] != 0) root_length++;
    while (root_length > 3 && (root[root_length - 1] == L'\\' || root[root_length - 1] == L'/')) root_length--;
    if (root_length == 0 || root_length >= 32767 || !QueryFullProcessImageNameW(process, 0, executable, &length) || length <= root_length ||
        CompareStringOrdinal(executable, (int)root_length, root, (int)root_length, TRUE) != CSTR_EQUAL ||
        executable[root_length] != L'\\') goto done;
    if (family != NULL && family[0] != 0) {
        WCHAR found[256]; UINT32 capacity = 256;
        if (GetPackageFamilyName(process, &capacity, found) != ERROR_SUCCESS ||
            CompareStringOrdinal(found, -1, family, -1, TRUE) != CSTR_EQUAL) goto done;
    }
    identity->pid = pid; identity->parent = 0; identity->started = pacer_process_start(process);
    matched = identity->started != 0;
done:
    CloseHandle(process); return matched;
}
void *pacer_pipe_open(const uint16_t *name, const uint16_t *root, const uint16_t *family, uint32_t timeout_ms, int32_t *failure) {
    if (failure != NULL) *failure = 1;
    if (name == NULL || root == NULL || timeout_ms == 0 || timeout_ms > 5000) return NULL;
    size_t length = 0;
    while (length <= 100 && name[length] != 0) {
        uint16_t c = name[length++];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_')) return NULL;
    }
    if (length == 0 || length > 100) return NULL;
    WCHAR path[112] = L"\\\\.\\pipe\\";
    memcpy(path + 9, name, (length + 1) * sizeof(WCHAR));
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (file == INVALID_HANDLE_VALUE && GetLastError() == ERROR_PIPE_BUSY && WaitNamedPipeW(path, timeout_ms))
        file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    pacer_process_identity peer = {0};
    if (!pacer_pipe_peer(file, (LPCWSTR)root, (LPCWSTR)family, &peer)) {
        if (failure != NULL) *failure = 2;
        CloseHandle(file); return NULL;
    }
    PacerPipe *pipe = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(PacerPipe));
    if (pipe == NULL) { CloseHandle(file); return NULL; }
    pipe->file = file;
    pipe->peer = peer;
    pipe->stopped = CreateEventW(NULL, TRUE, FALSE, NULL);
    pipe->read_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    pipe->write_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    InitializeSRWLock(&pipe->read_lock); InitializeSRWLock(&pipe->write_lock);
    if (pipe->stopped == NULL || pipe->read_event == NULL || pipe->write_event == NULL) { pacer_pipe_close(pipe); return NULL; }
    if (failure != NULL) *failure = 0;
    return pipe;
}
int pacer_pipe_peer_identity(void *value, pacer_process_identity *identity) {
    if (value == NULL || identity == NULL) return 0;
    *identity = ((PacerPipe *)value)->peer; return identity->pid != 0 && identity->started != 0;
}
static int64_t pacer_pipe_io(PacerPipe *pipe, uint8_t *bytes, size_t capacity, uint32_t timeout_ms, int writing) {
    if (pipe == NULL || bytes == NULL || capacity == 0 || capacity > 1024 * 1024) return -1;
    SRWLOCK *lock = writing ? &pipe->write_lock : &pipe->read_lock;
    AcquireSRWLockExclusive(lock);
    int64_t result = -1;
    if (InterlockedCompareExchange(&pipe->cancelled, 0, 0)) { result = -3; goto done; }
    OVERLAPPED operation = {0}; DWORD count = 0;
    operation.hEvent = writing ? pipe->write_event : pipe->read_event;
    ResetEvent(operation.hEvent);
    BOOL immediate = writing ? WriteFile(pipe->file, bytes, (DWORD)capacity, &count, &operation) : ReadFile(pipe->file, bytes, (DWORD)capacity, &count, &operation);
    if (immediate) { result = count; goto done; }
    DWORD error = GetLastError();
    if (error == ERROR_OPERATION_ABORTED && InterlockedCompareExchange(&pipe->cancelled, 0, 0)) { result = -3; goto done; }
    if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA) { result = 0; goto done; }
    if (error != ERROR_IO_PENDING) goto done;
    HANDLE events[2] = {pipe->stopped, operation.hEvent};
    DWORD waited = WaitForMultipleObjects(2, events, FALSE, timeout_ms);
    if (waited != WAIT_OBJECT_0 + 1) CancelIoEx(pipe->file, &operation);
    BOOL completed = GetOverlappedResult(pipe->file, &operation, &count, TRUE);
    error = completed ? ERROR_SUCCESS : GetLastError();
    if (waited == WAIT_OBJECT_0) result = -3;
    else if (completed) result = count;
    else if (waited == WAIT_TIMEOUT) result = -2;
    else if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA) result = 0;
done:
    ReleaseSRWLockExclusive(lock); return result;
}
int64_t pacer_pipe_read(void *pipe, uint8_t *bytes, size_t capacity, uint32_t timeout_ms) { return pacer_pipe_io(pipe, bytes, capacity, timeout_ms, 0); }
int64_t pacer_pipe_write(void *pipe, const uint8_t *bytes, size_t count, uint32_t timeout_ms) { return pacer_pipe_io(pipe, (uint8_t *)bytes, count, timeout_ms, 1); }
void pacer_pipe_cancel(void *value) {
    if (value == NULL) return;
    PacerPipe *pipe = value;
    InterlockedExchange(&pipe->cancelled, 1);
    if (pipe->stopped != NULL) SetEvent(pipe->stopped);
    CancelIoEx(pipe->file, NULL);
}
void pacer_pipe_close(void *value) {
    if (value == NULL) return;
    PacerPipe *pipe = value; pacer_pipe_cancel(pipe);
    CloseHandle(pipe->file);
    if (pipe->stopped != NULL) CloseHandle(pipe->stopped);
    if (pipe->read_event != NULL) CloseHandle(pipe->read_event);
    if (pipe->write_event != NULL) CloseHandle(pipe->write_event);
    HeapFree(GetProcessHeap(), 0, pipe);
}
#else
int pacer_pipe_peer_identity(void *pipe, pacer_process_identity *identity) { return 0; }
void *pacer_pipe_open(const uint16_t *name, const uint16_t *root, const uint16_t *family, uint32_t timeout_ms, int32_t *failure) { if (failure) *failure = 1; return NULL; }
int64_t pacer_pipe_read(void *pipe, uint8_t *bytes, size_t capacity, uint32_t timeout_ms) { return -1; }
int64_t pacer_pipe_write(void *pipe, const uint8_t *bytes, size_t count, uint32_t timeout_ms) { return -1; }
void pacer_pipe_cancel(void *pipe) {}
void pacer_pipe_close(void *pipe) {}
#endif
