#include "CWindowsSupport.h"
#if defined(_WIN32)
#include "WindowsProcessInternal.h"
#include <RestartManager.h>
#include <ProcessSnapshot.h>
#include <winternl.h>
#include <wchar.h>

typedef NTSTATUS (NTAPI *PacerQueryObject)(HANDLE, OBJECT_INFORMATION_CLASS, PVOID, ULONG, PULONG);

static int pacer_same_file(const FILE_ID_INFO *a, const FILE_ID_INFO *b) {
    return a->VolumeSerialNumber == b->VolumeSerialNumber && memcmp(&a->FileId, &b->FileId, sizeof(a->FileId)) == 0;
}
static HANDLE pacer_path_identity(LPCWSTR path, FILE_ID_INFO *identity, int directory) {
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file == INVALID_HANDLE_VALUE) return INVALID_HANDLE_VALUE;
    FILE_STANDARD_INFO standard;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandleEx(file, FileStandardInfo, &standard, sizeof(standard)) || (standard.Directory != 0) != (directory != 0) ||
        !GetFileInformationByHandleEx(file, FileIdInfo, identity, sizeof(*identity))) { CloseHandle(file); return INVALID_HANDLE_VALUE; }
    return file;
}
static HANDLE pacer_file_identity(LPCWSTR path, FILE_ID_INFO *identity) { return pacer_path_identity(path, identity, 0); }
int pacer_same_directory(const uint16_t *first, const uint16_t *second) {
    if (first == NULL || second == NULL) return 0;
    FILE_ID_INFO first_id, second_id;
    HANDLE left = pacer_path_identity((LPCWSTR)first, &first_id, 1);
    if (left == INVALID_HANDLE_VALUE) return 0;
    HANDLE right = pacer_path_identity((LPCWSTR)second, &second_id, 1);
    int same = right != INVALID_HANDLE_VALUE && pacer_same_file(&first_id, &second_id);
    if (right != INVALID_HANDLE_VALUE) CloseHandle(right);
    CloseHandle(left); return same;
}
// Windows 10 hands each handle's object-name buffer to its snapshot store but clears
// that buffer only when names are captured. Without the name flag it copies whatever
// length and pointer its own stack held there, which can stop the engine with an
// access violation in ntdll. Windows 11 clears the buffer either way. The capture
// never asks a File handle for its name, so a busy pipe cannot stall it.
static DWORD pacer_capture_handles(HANDLE process, HPSS *snapshot) {
    return PssCaptureSnapshot(process, PSS_CAPTURE_HANDLES | PSS_CAPTURE_HANDLE_NAME_INFORMATION | PSS_CAPTURE_HANDLE_BASIC_INFORMATION,
                              0, snapshot);
}
int pacer_handle_capture_names(const uint16_t *name) {
    size_t wanted = name == NULL ? 0 : wcsnlen((LPCWSTR)name, 256);
    if (wanted == 0 || wanted == 256) return -1;
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_DUP_HANDLE, FALSE, GetCurrentProcessId());
    if (process == NULL) return -1;
    HPSS snapshot = NULL; HPSSWALK marker = NULL; int found = -1;
    if (pacer_capture_handles(process, &snapshot) == ERROR_SUCCESS && PssWalkMarkerCreate(NULL, &marker) == ERROR_SUCCESS) {
        PSS_HANDLE_ENTRY entry; DWORD status = ERROR_SUCCESS; found = 0;
        while (!found && (status = PssWalkSnapshot(snapshot, PSS_WALK_HANDLES, marker, &entry, sizeof(entry))) == ERROR_SUCCESS) {
            if (!(entry.Flags & PSS_HANDLE_HAVE_NAME) || entry.ObjectName == NULL) continue;
            size_t length = wcsnlen(entry.ObjectName, entry.ObjectNameLength / sizeof(WCHAR));
            found = length >= wanted && wcsncmp(entry.ObjectName + length - wanted, (LPCWSTR)name, wanted) == 0;
        }
        // Only the end of the handles shows that the name is absent.
        if (!found && status != ERROR_NO_MORE_ITEMS) found = -1;
    }
    if (marker != NULL) PssWalkMarkerFree(marker);
    if (snapshot != NULL) PssFreeSnapshot(GetCurrentProcess(), snapshot);
    CloseHandle(process); return found;
}
static int pacer_has_write_handle(HANDLE process, const FILE_ID_INFO *wanted, PacerQueryObject query) {
    HPSS snapshot = NULL; HPSSWALK marker = NULL;
    DWORD status = pacer_capture_handles(process, &snapshot);
    if (status != ERROR_SUCCESS) return -1;
    int matched = 0;
    PSS_HANDLE_INFORMATION counts;
    if (PssQuerySnapshot(snapshot, PSS_QUERY_HANDLE_INFORMATION, &counts, sizeof(counts)) != ERROR_SUCCESS || counts.HandlesCaptured > 8192 ||
        PssWalkMarkerCreate(NULL, &marker) != ERROR_SUCCESS) { matched = -1; goto done; }
    PSS_HANDLE_ENTRY entry;
    size_t walked = 0;
    while ((status = PssWalkSnapshot(snapshot, PSS_WALK_HANDLES, marker, &entry, sizeof(entry))) == ERROR_SUCCESS && walked++ < 8192) {
        if (!(entry.Flags & PSS_HANDLE_HAVE_BASIC_INFORMATION) || !(entry.GrantedAccess & (FILE_WRITE_DATA | FILE_APPEND_DATA))) continue;
        HANDLE copy = NULL;
        if (!DuplicateHandle(process, entry.Handle, GetCurrentProcess(), &copy, 0, FALSE, DUPLICATE_SAME_ACCESS)) continue;
        // Confirm the duplicated handle's current rights as well. The target
        // may have closed and reused the numeric handle after the snapshot.
        PUBLIC_OBJECT_BASIC_INFORMATION rights = {0}; ULONG length = 0;
        FILE_ID_INFO found;
        if (query(copy, ObjectBasicInformation, &rights, sizeof(rights), &length) >= 0 &&
            (rights.GrantedAccess & (FILE_WRITE_DATA | FILE_APPEND_DATA)) && GetFileType(copy) == FILE_TYPE_DISK &&
            GetFileInformationByHandleEx(copy, FileIdInfo, &found, sizeof(found)) && pacer_same_file(wanted, &found)) matched = 1;
        CloseHandle(copy);
        if (matched == 1) break;
    }
    if (matched == 0 && status != ERROR_NO_MORE_ITEMS) matched = -1;
done:
    if (marker != NULL) PssWalkMarkerFree(marker);
    PssFreeSnapshot(GetCurrentProcess(), snapshot); return matched;
}
static int pacer_file_under(HANDLE file, LPCWSTR home, FILE_ID_INFO *root_id) {
    HANDLE root = CreateFileW(home, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (root == INVALID_HANDLE_VALUE) return 0;
    FILE_STANDARD_INFO standard; int valid = 0;
    WCHAR *paths = HeapAlloc(GetProcessHeap(), 0, 2 * 32768 * sizeof(WCHAR));
    if (paths != NULL && GetFileInformationByHandleEx(root, FileStandardInfo, &standard, sizeof(standard)) && standard.Directory &&
        GetFileInformationByHandleEx(root, FileIdInfo, root_id, sizeof(*root_id))) {
        DWORD root_length = GetFinalPathNameByHandleW(root, paths, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
        DWORD file_length = GetFinalPathNameByHandleW(file, paths + 32768, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
        if (root_length > 0 && root_length < 32768 && file_length > 0 && file_length < 32768) {
            while (root_length > 0 && paths[root_length - 1] == L'\\') root_length--;
            valid = file_length > root_length && paths[32768 + root_length] == L'\\' &&
                CompareStringOrdinal(paths, (int)root_length, paths + 32768, (int)root_length, TRUE) == CSTR_EQUAL;
            if (valid) {
                // NTFS can enable case-sensitive directories. A textual match
                // must also resolve to the exact selected directory object.
                paths[32768 + root_length] = 0;
                HANDLE ancestor = CreateFileW(paths + 32768, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
                FILE_ID_INFO ancestor_id;
                valid = ancestor != INVALID_HANDLE_VALUE && GetFileInformationByHandleEx(ancestor, FileIdInfo, &ancestor_id, sizeof(ancestor_id)) &&
                    pacer_same_file(root_id, &ancestor_id);
                if (ancestor != INVALID_HANDLE_VALUE) CloseHandle(ancestor);
            }
        }
    }
    if (paths != NULL) HeapFree(GetProcessHeap(), 0, paths);
    CloseHandle(root); return valid;
}
static int pacer_writers_within(const uint16_t *home, const uint16_t *path, pacer_process_identity *writers, size_t capacity) {
    if (path == NULL || writers == NULL || capacity == 0 || capacity > 64) return -1;
    PacerQueryObject query = (PacerQueryObject)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryObject");
    if (query == NULL) return -1;
    FILE_ID_INFO wanted;
    HANDLE target = pacer_file_identity((LPCWSTR)path, &wanted);
    if (target == INVALID_HANDLE_VALUE) return -1;
    FILE_ID_INFO root_id;
    if (home != NULL && !pacer_file_under(target, (LPCWSTR)home, &root_id)) { CloseHandle(target); return -1; }
    DWORD session = 0; WCHAR key[CCH_RM_SESSION_KEY + 1] = {0}; int result = -1;
    if (RmStartSession(&session, 0, key) != ERROR_SUCCESS) { CloseHandle(target); return -1; }
    LPCWSTR files[1] = {(LPCWSTR)path};
    if (RmRegisterResources(session, 1, files, 0, NULL, 0, NULL) != ERROR_SUCCESS) goto done;
    RM_PROCESS_INFO processes[64]; UINT count = 64, needed = 0; DWORD reason = 0;
    if (RmGetList(session, &needed, &count, processes, &reason) != ERROR_SUCCESS || count > 64) goto done;
    int unknown = 0; size_t matches = 0;
    for (UINT index = 0; index < count; index++) {
        RM_UNIQUE_PROCESS candidate = processes[index].Process;
        if (candidate.dwProcessId == GetCurrentProcessId()) continue;
        uint64_t started = ((uint64_t)candidate.ProcessStartTime.dwHighDateTime << 32) | candidate.ProcessStartTime.dwLowDateTime;
        HANDLE process = pacer_open_user_process(candidate.dwProcessId, PROCESS_QUERY_INFORMATION | PROCESS_DUP_HANDLE, started);
        if (process == NULL) continue;
        int found = pacer_has_write_handle(process, &wanted, query);
        if (found == 1 && pacer_process_start(process) == started) {
            if (matches == capacity) { unknown = 1; CloseHandle(process); break; }
            writers[matches++] = (pacer_process_identity){candidate.dwProcessId, 0, started};
        } else if (found < 0) unknown = 1;
        CloseHandle(process);
    }
    FILE_ID_INFO current;
    HANDLE check = pacer_file_identity((LPCWSTR)path, &current);
    if (check != INVALID_HANDLE_VALUE) {
        FILE_ID_INFO current_root;
        int scoped = home == NULL || (pacer_file_under(check, (LPCWSTR)home, &current_root) && pacer_same_file(&root_id, &current_root));
        if (pacer_same_file(&wanted, &current) && scoped && !unknown) result = (int)matches;
        CloseHandle(check);
    }
done:
    RmEndSession(session); CloseHandle(target); return result;
}
int pacer_source_file_stamp(const uint16_t *home, const uint16_t *path, pacer_source_file_identity *stamp) {
    if (home == NULL || path == NULL || stamp == NULL) return 0;
    FILE_ID_INFO file_id, root_id;
    HANDLE file = pacer_file_identity((LPCWSTR)path, &file_id);
    if (file == INVALID_HANDLE_VALUE) return 0;
    int valid = pacer_file_under(file, (LPCWSTR)home, &root_id);
    if (valid) {
        stamp->file_volume = file_id.VolumeSerialNumber; stamp->root_volume = root_id.VolumeSerialNumber;
        memcpy(&stamp->file_low, &file_id.FileId.Identifier[0], 8); memcpy(&stamp->file_high, &file_id.FileId.Identifier[8], 8);
        memcpy(&stamp->root_low, &root_id.FileId.Identifier[0], 8); memcpy(&stamp->root_high, &root_id.FileId.Identifier[8], 8);
    }
    CloseHandle(file); return valid;
}
int pacer_file_writers(const uint16_t *path, pacer_process_identity *writers, size_t capacity) { return pacer_writers_within(NULL, path, writers, capacity); }
int pacer_scoped_file_writers(const uint16_t *home, const uint16_t *path, pacer_process_identity *writers, size_t capacity) {
    if (home == NULL) return -1;
    return pacer_writers_within(home, path, writers, capacity);
}
#else
int pacer_handle_capture_names(const uint16_t *name) { return -1; }
int pacer_same_directory(const uint16_t *first, const uint16_t *second) { return 0; }
int pacer_source_file_stamp(const uint16_t *home, const uint16_t *path, pacer_source_file_identity *stamp) { return 0; }
int pacer_file_writers(const uint16_t *path, pacer_process_identity *writers, size_t capacity) { return -1; }
int pacer_scoped_file_writers(const uint16_t *home, const uint16_t *path, pacer_process_identity *writers, size_t capacity) { return -1; }
#endif
