#include "CWindowsSupport.h"
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <wincred.h>
#include <appmodel.h>
#include <string.h>
#include <wchar.h>
#include <winver.h>

int pacer_sha256(const uint8_t *bytes, size_t count, uint8_t output[32]) {
    if (count > UINT32_MAX) return 0;
    BCRYPT_ALG_HANDLE algorithm = NULL;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) return 0;
    NTSTATUS status = BCryptHash(algorithm, NULL, 0, (PUCHAR)bytes, (ULONG)count, output, 32);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return status >= 0;
}
int pacer_replace_file(const uint16_t *source, const uint16_t *destination) {
    return MoveFileExW((LPCWSTR)source, (LPCWSTR)destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}
int pacer_read_credential(const uint16_t *name, uint8_t *bytes, size_t capacity) {
    PCREDENTIALW credential = NULL;
    if (!CredReadW((LPCWSTR)name, CRED_TYPE_GENERIC, 0, &credential)) return -1;
    int count = -1;
    if (credential->CredentialBlobSize <= capacity) {
        count = (int)credential->CredentialBlobSize;
        memcpy(bytes, credential->CredentialBlob, count);
    }
    CredFree(credential);
    return count;
}
int pacer_write_credential(const uint16_t *name, const uint8_t *bytes, size_t count) {
    if (count == 0 || count > CRED_MAX_CREDENTIAL_BLOB_SIZE) return 0;
    CREDENTIALW credential = {0};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = (LPWSTR)name;
    credential.CredentialBlobSize = (DWORD)count;
    credential.CredentialBlob = (LPBYTE)bytes;
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&credential, 0) != 0;
}
int pacer_remove_credential(const uint16_t *name) {
    if (CredDeleteW((LPCWSTR)name, CRED_TYPE_GENERIC, 0)) return 1;
    return GetLastError() == ERROR_NOT_FOUND;
}
int pacer_normalize_ipv6(const char *input, char *output, size_t capacity) {
    IN6_ADDR address;
    if (capacity < INET6_ADDRSTRLEN || InetPtonA(AF_INET6, input, &address) != 1) return 0;
    return InetNtopA(AF_INET6, &address, output, capacity) != NULL;
}
int64_t pacer_read_stdin(uint8_t *bytes, size_t capacity) {
    if (capacity == 0 || capacity > UINT32_MAX) return -1;
    DWORD count = 0;
    if (ReadFile(GetStdHandle(STD_INPUT_HANDLE), bytes, (DWORD)capacity, &count, NULL)) return count;
    return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
}
int pacer_named_semaphore_exists(const uint16_t *name) {
    HANDLE handle = OpenSemaphoreW(SYNCHRONIZE, FALSE, (LPCWSTR)name);
    if (handle == NULL) return 0;
    CloseHandle(handle);
    return 1;
}
typedef struct {
    SRWLOCK lock;
    HANDLE notification;
    PTP_WAIT wait;
    int stopped;
    void *context;
    pacer_change_callback callback;
} PacerDirectoryWatch;

static void CALLBACK pacer_directory_changed(PTP_CALLBACK_INSTANCE instance, void *context, PTP_WAIT wait, TP_WAIT_RESULT result) {
    (void)instance; (void)wait; (void)result;
    PacerDirectoryWatch *watch = context;
    AcquireSRWLockExclusive(&watch->lock);
    if (watch->stopped) { ReleaseSRWLockExclusive(&watch->lock); return; }
    int valid = FindNextChangeNotification(watch->notification) != 0;
    if (valid) SetThreadpoolWait(watch->wait, watch->notification, NULL);
    ReleaseSRWLockExclusive(&watch->lock);
    // The Swift callback only queues work. Closing waits for this call to
    // return before releasing its context; it never closes from this callback.
    watch->callback(watch->context, valid);
}

void *pacer_watch_directory(const uint16_t *path, int names_only, void *context, pacer_change_callback callback) {
    if (path == NULL || context == NULL || callback == NULL) return NULL;
    DWORD flags = names_only ? FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME
                            : FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE;
    HANDLE notification = FindFirstChangeNotificationW((LPCWSTR)path, TRUE, flags);
    if (notification == INVALID_HANDLE_VALUE) return NULL;
    PacerDirectoryWatch *watch = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*watch));
    if (watch == NULL) { FindCloseChangeNotification(notification); return NULL; }
    InitializeSRWLock(&watch->lock);
    watch->notification = notification; watch->context = context; watch->callback = callback;
    watch->wait = CreateThreadpoolWait(pacer_directory_changed, watch, NULL);
    if (watch->wait == NULL) {
        FindCloseChangeNotification(notification); HeapFree(GetProcessHeap(), 0, watch); return NULL;
    }
    SetThreadpoolWait(watch->wait, notification, NULL);
    return watch;
}

void pacer_close_directory_watch(void *value) {
    if (value == NULL) return;
    PacerDirectoryWatch *watch = value;
    AcquireSRWLockExclusive(&watch->lock);
    watch->stopped = 1; SetThreadpoolWait(watch->wait, NULL, NULL);
    ReleaseSRWLockExclusive(&watch->lock);
    WaitForThreadpoolWaitCallbacks(watch->wait, TRUE);
    CloseThreadpoolWait(watch->wait);
    FindCloseChangeNotification(watch->notification);
    HeapFree(GetProcessHeap(), 0, watch);
}
int pacer_is_windows_executable(const uint16_t *path) {
    DWORD type = 0;
    return path != NULL && GetBinaryTypeW((LPCWSTR)path, &type) && (type == SCS_32BIT_BINARY || type == SCS_64BIT_BINARY);
}

static int pacer_version_string(const void *block, size_t size, WORD language, WORD codepage, LPCWSTR field, LPCWSTR expected) {
    WCHAR query[128]; LPVOID found = NULL; UINT length = 0;
    if (swprintf(query, 128, L"\\StringFileInfo\\%04x%04x\\%ls", (unsigned)language, (unsigned)codepage, field) < 0 ||
        !VerQueryValueW(block, query, &found, &length) || found == NULL || length == 0 || length > 32768) return 0;
    uintptr_t start = (uintptr_t)found, base = (uintptr_t)block;
    if (start < base || start - base > size || (size_t)length * sizeof(WCHAR) > size - (start - base)) return 0;
    LPCWSTR text = found; size_t count = 0;
    while (count < length && text[count] != 0) count++;
    return count < length && CompareStringOrdinal(text, (int)count, expected, -1, TRUE) == CSTR_EQUAL;
}
int pacer_windows_product_matches(const uint16_t *path, const uint16_t *product, const uint16_t *company) {
    if (path == NULL || product == NULL || company == NULL || !pacer_is_windows_executable(path)) return 0;
    DWORD ignored = 0, size = GetFileVersionInfoSizeW((LPCWSTR)path, &ignored);
    if (size == 0 || size > 1024 * 1024) return 0;
    void *block = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    if (block == NULL) return 0;
    int matched = 0;
    if (GetFileVersionInfoW((LPCWSTR)path, 0, size, block)) {
        struct PacerTranslation { WORD language, codepage; } *translations = NULL;
        UINT bytes = 0;
        if (VerQueryValueW(block, L"\\VarFileInfo\\Translation", (LPVOID *)&translations, &bytes) && translations != NULL &&
            (uintptr_t)translations >= (uintptr_t)block && (uintptr_t)translations - (uintptr_t)block <= size &&
            bytes <= size - ((uintptr_t)translations - (uintptr_t)block)) {
            size_t count = bytes / sizeof(*translations); if (count > 32) count = 32;
            for (size_t i = 0; i < count && !matched; i++) {
                matched = pacer_version_string(block, size, translations[i].language, translations[i].codepage, L"ProductName", (LPCWSTR)product) &&
                    pacer_version_string(block, size, translations[i].language, translations[i].codepage, L"CompanyName", (LPCWSTR)company);
            }
        }
    }
    HeapFree(GetProcessHeap(), 0, block); return matched;
}
int pacer_harness_registry_path(size_t index, uint16_t *path, size_t capacity) {
    if (index >= 4 || path == NULL || capacity == 0 || capacity > 32768) return 0;
    LPCWSTR key = index < 2 ? L"Software\\Classes\\dsh\\shell\\open\\command"
        : L"Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\DeepSeek Harness.exe";
    WCHAR command[32768] = {0}; DWORD bytes = sizeof(command);
    HKEY root = index % 2 == 0 ? HKEY_CURRENT_USER : HKEY_LOCAL_MACHINE;
    if (RegGetValueW(root, key, NULL, RRF_RT_REG_SZ, NULL, command, &bytes) != ERROR_SUCCESS || bytes == 0 || bytes > sizeof(command)) return 0;
    size_t begin = 0, end = 0, limit = bytes / sizeof(WCHAR);
    if (command[0] == L'"') { begin = 1; end = 1; while (end < limit && command[end] != 0 && command[end] != L'"') end++; if (end == limit || command[end] != L'"') return 0; }
    else { if (index < 2) return 0; while (end < limit && command[end] != 0) end++; if (end == limit) return 0; }
    size_t length = end - begin;
    if (length == 0 || length >= capacity) return 0;
    memcpy(path, command + begin, length * sizeof(uint16_t)); path[length] = 0; return 1;
}
int pacer_package_path(const uint16_t *family, size_t index, uint16_t *path, size_t capacity) {
    if (family == NULL || path == NULL || capacity == 0 || capacity > 32768) return 0;
    size_t family_length = 0;
    while (family_length < 255 && family[family_length] != 0) family_length++;
    if (family_length == 0 || family_length == 255) return 0;
    UINT32 count = 0, length = 0;
    LONG result = GetPackagesByPackageFamily((LPCWSTR)family, &count, NULL, &length, NULL);
    if (result != ERROR_INSUFFICIENT_BUFFER || count == 0 || count > 32 || length == 0 || length > 65536 || index >= count) return 0;
    PWSTR *names = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, count * sizeof(PWSTR));
    WCHAR *buffer = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, length * sizeof(WCHAR));
    if (names == NULL || buffer == NULL) {
        if (names != NULL) HeapFree(GetProcessHeap(), 0, names);
        if (buffer != NULL) HeapFree(GetProcessHeap(), 0, buffer);
        return 0;
    }
    result = GetPackagesByPackageFamily((LPCWSTR)family, &count, names, &length, buffer);
    UINT32 path_length = (UINT32)capacity;
    if (result == ERROR_SUCCESS && index < count) result = GetPackagePathByFullName(names[index], &path_length, (PWSTR)path);
    HeapFree(GetProcessHeap(), 0, names); HeapFree(GetProcessHeap(), 0, buffer);
    return result == ERROR_SUCCESS;
}
int pacer_codex_package_path(size_t index, uint16_t *path, size_t capacity) {
    return pacer_package_path((const uint16_t *)L"OpenAI.Codex_2p2nqsd0c76g0", index, path, capacity);
}
#else
// This target is only a dependency on Windows.
int pacer_sha256(const uint8_t *bytes, size_t count, uint8_t output[32]) { return 0; }
int pacer_replace_file(const uint16_t *source, const uint16_t *destination) { return 0; }
int pacer_read_credential(const uint16_t *name, uint8_t *bytes, size_t capacity) { return -1; }
int pacer_write_credential(const uint16_t *name, const uint8_t *bytes, size_t count) { return 0; }
int pacer_remove_credential(const uint16_t *name) { return 0; }
int pacer_normalize_ipv6(const char *input, char *output, size_t capacity) { return 0; }
int64_t pacer_read_stdin(uint8_t *bytes, size_t capacity) { return -1; }
int pacer_named_semaphore_exists(const uint16_t *name) { return 0; }
void *pacer_watch_directory(const uint16_t *path, int names_only, void *context, pacer_change_callback callback) { return NULL; }
void pacer_close_directory_watch(void *watch) {}
int pacer_is_windows_executable(const uint16_t *path) { return 0; }
int pacer_windows_product_matches(const uint16_t *path, const uint16_t *product, const uint16_t *company) { return 0; }
int pacer_harness_registry_path(size_t index, uint16_t *path, size_t capacity) { return 0; }
int pacer_codex_package_path(size_t index, uint16_t *path, size_t capacity) { return 0; }
int pacer_package_path(const uint16_t *family, size_t index, uint16_t *path, size_t capacity) { return 0; }
#endif
