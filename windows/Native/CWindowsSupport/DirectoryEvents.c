#include "CWindowsSupport.h"
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct {
    SRWLOCK lock;
    HANDLE directory, event;
    OVERLAPPED overlapped;
    PTP_WAIT wait;
    PTP_WORK cleanup;
    int stopped;
    WCHAR *filename;
    void *context;
    pacer_change_callback callback;
    void (*closed)(void *);
    unsigned char buffer[64 * 1024];
} PacerDirectoryWatch;

static void CALLBACK pacer_directory_release(PTP_CALLBACK_INSTANCE, void *, PTP_WORK);

static int pacer_directory_read(PacerDirectoryWatch *watch) {
    ZeroMemory(&watch->overlapped, sizeof(watch->overlapped));
    watch->overlapped.hEvent = watch->event;
    ResetEvent(watch->event);
    DWORD flags = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                  FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE;
    if (!ReadDirectoryChangesW(watch->directory, watch->buffer, sizeof(watch->buffer),
                               watch->filename == NULL, flags, NULL, &watch->overlapped, NULL)) return 0;
    SetThreadpoolWait(watch->wait, watch->event, NULL);
    return 1;
}

static void CALLBACK pacer_directory_changed(PTP_CALLBACK_INSTANCE instance, void *context, PTP_WAIT wait, TP_WAIT_RESULT result) {
    (void)instance; (void)wait; (void)result;
    PacerDirectoryWatch *watch = context;
    int changed = 0, flags = 0;
    AcquireSRWLockExclusive(&watch->lock);
    if (watch->stopped) { ReleaseSRWLockExclusive(&watch->lock); return; }
    DWORD count = 0;
    if (!GetOverlappedResult(watch->directory, &watch->overlapped, &count, FALSE)) {
        changed = 1; flags = 3;
    } else if (count == 0) {
        // Overflow requests discovery; it never becomes a polling loop.
        changed = 1; flags = 2;
    } else {
        DWORD offset = 0;
        while (offset < count) {
            FILE_NOTIFY_INFORMATION *entry = (FILE_NOTIFY_INFORMATION *)(watch->buffer + offset);
            DWORD header = (DWORD)FIELD_OFFSET(FILE_NOTIFY_INFORMATION, FileName);
            if (count - offset < header || entry->FileNameLength > count - offset - header || entry->FileNameLength % sizeof(WCHAR)) {
                changed = 1; flags |= 2; break;
            }
            size_t length = entry->FileNameLength / sizeof(WCHAR);
            int matches = watch->filename == NULL ||
                (wcslen(watch->filename) == length && _wcsnicmp(watch->filename, entry->FileName, length) == 0);
            if (matches) {
                changed = 1;
                if (entry->Action != FILE_ACTION_MODIFIED) {
                    flags |= 2;
                    if (watch->filename != NULL && (entry->Action == FILE_ACTION_REMOVED || entry->Action == FILE_ACTION_RENAMED_OLD_NAME)) flags |= 1;
                }
            }
            if (entry->NextEntryOffset == 0) break;
            if (entry->NextEntryOffset < header || entry->NextEntryOffset > count - offset) { changed = 1; flags |= 2; break; }
            offset += entry->NextEntryOffset;
        }
    }
    if (!(flags & 1) && !pacer_directory_read(watch)) { changed = 1; flags |= 3; }
    ReleaseSRWLockExclusive(&watch->lock);
    if (changed) watch->callback(watch->context, flags);
}

void *pacer_watch_directory(const uint16_t *path, int is_directory, void *context,
                           pacer_change_callback callback, void (*closed)(void *)) {
    if (path == NULL || context == NULL || callback == NULL || closed == NULL) return NULL;
    WCHAR *directory = _wcsdup((LPCWSTR)path), *filename = NULL;
    if (directory == NULL) return NULL;
    if (!is_directory) {
        WCHAR *last = wcsrchr(directory, L'\\');
        if (last == NULL || last[1] == 0) { free(directory); return NULL; }
        filename = _wcsdup(last + 1);
        if ((last == directory + 2 && directory[1] == L':') ||
            (last == directory + 6 && wcsncmp(directory, L"\\\\?\\", 4) == 0 && directory[5] == L':')) last[1] = 0; else *last = 0;
        if (filename == NULL) { free(directory); return NULL; }
    }
    HANDLE handle = CreateFileW(directory, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    free(directory);
    if (handle == INVALID_HANDLE_VALUE) { free(filename); return NULL; }
    PacerDirectoryWatch *watch = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*watch));
    if (watch == NULL) { CloseHandle(handle); free(filename); return NULL; }
    InitializeSRWLock(&watch->lock);
    watch->directory = handle; watch->filename = filename; watch->context = context;
    watch->callback = callback; watch->closed = closed;
    watch->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    watch->cleanup = CreateThreadpoolWork(pacer_directory_release, watch, NULL);
    if (watch->event != NULL) watch->wait = CreateThreadpoolWait(pacer_directory_changed, watch, NULL);
    if (watch->wait == NULL || watch->cleanup == NULL || !pacer_directory_read(watch)) {
        if (watch->wait != NULL) CloseThreadpoolWait(watch->wait);
        if (watch->cleanup != NULL) CloseThreadpoolWork(watch->cleanup);
        if (watch->event != NULL) CloseHandle(watch->event);
        CloseHandle(handle); free(filename); HeapFree(GetProcessHeap(), 0, watch); return NULL;
    }
    return watch;
}

static void CALLBACK pacer_directory_release(PTP_CALLBACK_INSTANCE instance, void *context, PTP_WORK cleanup) {
    (void)instance;
    PacerDirectoryWatch *watch = context;
    WaitForThreadpoolWaitCallbacks(watch->wait, TRUE);
    // CancelIoEx completion owns the OVERLAPPED storage until it is signalled.
    DWORD ignored = 0;
    (void)GetOverlappedResult(watch->directory, &watch->overlapped, &ignored, TRUE);
    CloseThreadpoolWait(watch->wait);
    CloseHandle(watch->event); CloseHandle(watch->directory);
    watch->closed(watch->context);
    free(watch->filename); HeapFree(GetProcessHeap(), 0, watch);
    CloseThreadpoolWork(cleanup);
}

void pacer_close_directory_watch(void *value) {
    if (value == NULL) return;
    PacerDirectoryWatch *watch = value;
    AcquireSRWLockExclusive(&watch->lock);
    watch->stopped = 1; SetThreadpoolWait(watch->wait, NULL, NULL);
    CancelIoEx(watch->directory, &watch->overlapped);
    ReleaseSRWLockExclusive(&watch->lock);
    // Drain OS completion off the caller's shutdown deadline.
    SubmitThreadpoolWork(watch->cleanup);
}
#endif
