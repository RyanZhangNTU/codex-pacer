#include "CWindowsSupport.h"
#if defined(_WIN32)
#include "WindowsProcessInternal.h"
#include <tlhelp32.h>

static void *pacer_token_user(HANDLE token) {
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &size);
    if (size == 0 || size > 4096) return NULL;
    void *data = HeapAlloc(GetProcessHeap(), 0, size);
    if (data != NULL && !GetTokenInformation(token, TokenUser, data, size, &size)) {
        HeapFree(GetProcessHeap(), 0, data); return NULL;
    }
    return data;
}
uint64_t pacer_process_start(HANDLE process) {
    FILETIME started, exited, kernel, user;
    if (!GetProcessTimes(process, &started, &exited, &kernel, &user)) return 0;
    return ((uint64_t)started.dwHighDateTime << 32) | started.dwLowDateTime;
}
HANDLE pacer_open_user_process(DWORD pid, DWORD access, uint64_t started) {
    DWORD own_session = 0, peer_session = 0;
    if (pid == 0 || !ProcessIdToSessionId(GetCurrentProcessId(), &own_session) || !ProcessIdToSessionId(pid, &peer_session) || own_session != peer_session) return NULL;
    HANDLE process = OpenProcess(access | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
    if (process == NULL) return NULL;
    if (WaitForSingleObject(process, 0) != WAIT_TIMEOUT) { CloseHandle(process); return NULL; }
    uint64_t actual = pacer_process_start(process);
    if (actual == 0 || (started != 0 && actual != started)) { CloseHandle(process); return NULL; }
    HANDLE own_token = NULL, peer_token = NULL; int matched = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &own_token) && OpenProcessToken(process, TOKEN_QUERY, &peer_token)) {
        TOKEN_USER *own = pacer_token_user(own_token), *peer = pacer_token_user(peer_token);
        matched = own != NULL && peer != NULL && IsValidSid(own->User.Sid) && IsValidSid(peer->User.Sid) && EqualSid(own->User.Sid, peer->User.Sid);
        if (own != NULL) HeapFree(GetProcessHeap(), 0, own);
        if (peer != NULL) HeapFree(GetProcessHeap(), 0, peer);
    }
    if (own_token != NULL) CloseHandle(own_token);
    if (peer_token != NULL) CloseHandle(peer_token);
    if (!matched) { CloseHandle(process); return NULL; }
    return process;
}
int pacer_process_alive(uint32_t pid, uint64_t started) {
    if (started == 0) return 0;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
    if (process == NULL) return 0;
    int alive = WaitForSingleObject(process, 0) == WAIT_TIMEOUT && pacer_process_start(process) == started;
    CloseHandle(process); return alive;
}
int pacer_process_image(uint32_t pid, uint64_t started, pacer_process_identity *identity, uint16_t *image, size_t capacity) {
    if (identity == NULL || image == NULL || capacity == 0 || capacity > 32768) return 0;
    HANDLE process = pacer_open_user_process(pid, PROCESS_QUERY_LIMITED_INFORMATION, started);
    if (process == NULL) return 0;
    DWORD length = (DWORD)capacity;
    int valid = QueryFullProcessImageNameW(process, 0, (LPWSTR)image, &length) && length < capacity;
    if (valid) {
        identity->pid = pid; identity->started = pacer_process_start(process); identity->parent = 0;
        valid = identity->started != 0 && (started == 0 || identity->started == started);
    }
    CloseHandle(process); return valid;
}
int pacer_process_parents(pacer_process_identity *identities, size_t capacity) {
    if (identities == NULL || capacity == 0 || capacity > 8192) return -1;
    HANDLE table = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (table == INVALID_HANDLE_VALUE) return -1;
    PROCESSENTRY32W entry = {0}; entry.dwSize = sizeof(entry); size_t count = 0;
    int valid = Process32FirstW(table, &entry) != 0;
    if (valid) do {
        if (count == capacity) { valid = 0; break; }
        identities[count++] = (pacer_process_identity){entry.th32ProcessID, entry.th32ParentProcessID, 0};
    } while (Process32NextW(table, &entry));
    CloseHandle(table); return valid ? (int)count : -1;
}
int pacer_process_details(uint32_t pid, uint64_t started, pacer_process_identity *identity, uint16_t *image, size_t capacity) {
    if (!pacer_process_image(pid, started, identity, image, capacity)) return 0;
    pacer_process_identity *rows = HeapAlloc(GetProcessHeap(), 0, 8192 * sizeof(*rows));
    if (rows == NULL) return 0;
    int count = pacer_process_parents(rows, 8192);
    for (int i = 0; i < count; ++i) if (rows[i].pid == pid) { identity->parent = rows[i].parent; break; }
    HeapFree(GetProcessHeap(), 0, rows); return count >= 0;
}
typedef struct { DWORD pid; HWND window; } pacer_window_search;
static BOOL CALLBACK pacer_find_process_window(HWND window, LPARAM argument) {
    pacer_window_search *search = (pacer_window_search *)argument;
    DWORD owner = 0;
    GetWindowThreadProcessId(window, &owner);
    if (owner != search->pid || !IsWindowVisible(window) || GetWindow(window, GW_OWNER) != NULL) return TRUE;
    search->window = window; return FALSE;
}
int pacer_process_window(uint32_t pid, uint64_t started, int activate) {
    if (started == 0 || (activate != 0 && activate != 1)) return 0;
    HANDLE process = pacer_open_user_process(pid, PROCESS_QUERY_LIMITED_INFORMATION, started);
    if (process == NULL) return 0;
    pacer_window_search search = { pid, NULL };
    EnumWindows(pacer_find_process_window, (LPARAM)&search);
    DWORD owner = 0;
    if (search.window != NULL) GetWindowThreadProcessId(search.window, &owner);
    int valid = search.window != NULL && owner == pid && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    if (valid && activate) {
        if (IsIconic(search.window)) ShowWindowAsync(search.window, SW_RESTORE);
        valid = SetForegroundWindow(search.window) || GetForegroundWindow() == search.window;
    }
    CloseHandle(process); return valid;
}
#else
int pacer_process_window(uint32_t pid, uint64_t started, int activate) { return 0; }
int pacer_process_alive(uint32_t pid, uint64_t started) { return 0; }
int pacer_process_details(uint32_t pid, uint64_t started, pacer_process_identity *identity, uint16_t *image, size_t capacity) { return 0; }
#endif
