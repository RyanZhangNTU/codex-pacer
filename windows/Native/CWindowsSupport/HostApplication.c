#include "CWindowsSupport.h"
#if defined(_WIN32)
#include "WindowsProcessInternal.h"
#include <appmodel.h>
#include <objbase.h>
#include <shellapi.h>
#include <wchar.h>

static HANDLE pacer_application_file(const WCHAR *path, pacer_application_stamp *stamp) {
    if (path == NULL || wcsnlen(path, 32768) >= 32768 || wcslen(path) < 7 ||
        !((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) ||
        path[1] != L':' || path[2] != L'\\' || _wcsicmp(path + wcslen(path) - 4, L".exe") != 0) return INVALID_HANDLE_VALUE;
    // Deny writes and replacement from verification through process creation.
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return file;
    FILE_ID_INFO id; BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandleEx(file, FileIdInfo, &id, sizeof(id)) || !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
        CloseHandle(file); return INVALID_HANDLE_VALUE;
    }
    stamp->volume = id.VolumeSerialNumber;
    memcpy(&stamp->low, id.FileId.Identifier, sizeof(uint64_t));
    memcpy(&stamp->high, id.FileId.Identifier + sizeof(uint64_t), sizeof(uint64_t));
    stamp->modified = ((uint64_t)info.ftLastWriteTime.dwHighDateTime << 32) | info.ftLastWriteTime.dwLowDateTime;
    stamp->size = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
    return file;
}
int pacer_process_application(uint32_t pid, uint64_t started, uint16_t *image, size_t capacity,
                              uint16_t *application_id, size_t id_capacity, pacer_application_stamp *stamp) {
    if (started == 0 || image == NULL || capacity == 0 || capacity > 32768 || application_id == NULL || id_capacity < 2 || id_capacity > 512 || stamp == NULL) return 0;
    HANDLE process = pacer_open_user_process(pid, PROCESS_QUERY_LIMITED_INFORMATION, started);
    if (process == NULL) return 0;
    DWORD length = (DWORD)capacity;
    int valid = QueryFullProcessImageNameW(process, 0, (LPWSTR)image, &length) && length < capacity;
    application_id[0] = 0;
    if (valid) {
        HANDLE file = pacer_application_file((LPCWSTR)image, stamp);
        valid = file != INVALID_HANDLE_VALUE && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        UINT32 package_length = 0, id_length = (UINT32)id_capacity;
        // Only package identity supplied by Windows, never a window property.
        LONG package = GetPackageFullName(process, &package_length, NULL);
        if (package == ERROR_INSUFFICIENT_BUFFER) {
            if (GetApplicationUserModelId(process, &id_length, (PWSTR)application_id) != ERROR_SUCCESS) valid = 0;
        } else if (package != APPMODEL_ERROR_NO_PACKAGE) valid = 0;
    }
    CloseHandle(process); return valid;
}
int pacer_application_open(const uint16_t *image, const uint16_t *application_id, const pacer_application_stamp *stamp) {
    if (image == NULL || application_id == NULL || stamp == NULL) return 0;
    pacer_application_stamp current = {0};
    HANDLE file = pacer_application_file((LPCWSTR)image, &current);
    if (file == INVALID_HANDLE_VALUE) return 0;
    int valid = current.volume == stamp->volume && current.low == stamp->low && current.high == stamp->high &&
        current.modified == stamp->modified && current.size == stamp->size;
    int opened = 0;
    if (valid && application_id[0] != 0) {
        size_t length = wcsnlen((LPCWSTR)application_id, 512);
        for (size_t i = 0; i < length; ++i) {
            WCHAR ch = application_id[i];
            if (!((ch >= L'A' && ch <= L'Z') || (ch >= L'a' && ch <= L'z') || (ch >= L'0' && ch <= L'9') ||
                  ch == L'.' || ch == L'_' || ch == L'-' || ch == L'!')) valid = 0;
        }
        if (length >= 512) valid = 0;
        if (valid) {
            WCHAR destination[540] = L"shell:AppsFolder\\";
            wcscat_s(destination, 540, (LPCWSTR)application_id);
            SHELLEXECUTEINFOW launch = {0}; launch.cbSize = sizeof(launch);
            launch.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI; launch.lpVerb = L"open";
            launch.lpFile = destination; launch.nShow = SW_SHOWNORMAL;
            HRESULT apartment = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
            if (SUCCEEDED(apartment) || apartment == RPC_E_CHANGED_MODE) opened = ShellExecuteExW(&launch) != 0;
            if (SUCCEEDED(apartment)) CoUninitialize();
        }
    } else if (valid) {
        WCHAR command[32770], directory[32768];
        _snwprintf_s(command, 32770, _TRUNCATE, L"\"%ls\"", (LPCWSTR)image);
        wcscpy_s(directory, 32768, (LPCWSTR)image);
        WCHAR *slash = wcsrchr(directory, L'\\'); if (slash != NULL) *slash = 0;
        STARTUPINFOW startup = {0}; startup.cb = sizeof(startup); PROCESS_INFORMATION process = {0};
        opened = CreateProcessW((LPCWSTR)image, command, NULL, NULL, FALSE, 0, NULL, directory, &startup, &process) != 0;
        if (opened) { CloseHandle(process.hThread); CloseHandle(process.hProcess); }
    }
    CloseHandle(file); return opened;
}
#endif
