#include "CWindowsSupport.h"
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static const WCHAR pacer_lxss[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Lxss";

int pacer_wsl_registration_presence(void) {
    HKEY key;
    LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, pacer_lxss, 0, KEY_READ, &key);
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return 0;
    if (status != ERROR_SUCCESS) return -1;
    int result = -1, incomplete = 0;
    for (DWORD index = 0; index < 128; ++index) {
        WCHAR name[256];
        DWORD length = ARRAYSIZE(name);
        status = RegEnumKeyExW(key, index, name, &length, NULL, NULL, NULL, NULL);
        if (status == ERROR_NO_MORE_ITEMS) { result = incomplete ? -1 : 0; break; }
        if (status != ERROR_SUCCESS) { incomplete = 1; continue; }
        DWORD bytes = 0;
        status = RegGetValueW(key, name, L"DistributionName", RRF_RT_REG_SZ, NULL, NULL, &bytes);
        if (status == ERROR_SUCCESS && bytes > sizeof(WCHAR)) { result = 1; break; }
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) incomplete = 1;
    }
    RegCloseKey(key);
    return result;
}

typedef struct {
    SRWLOCK lock;
    HKEY key;
    HANDLE event;
    PTP_WAIT wait;
    int stopped;
    void *context;
    pacer_change_callback callback;
    void (*closed)(void *);
} PacerWSLWatch;

static int pacer_arm_wsl_watch(PacerWSLWatch *watch) {
    if (RegNotifyChangeKeyValue(watch->key, TRUE, REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET |
                               REG_NOTIFY_THREAD_AGNOSTIC, watch->event, TRUE) != ERROR_SUCCESS) return 0;
    SetThreadpoolWait(watch->wait, watch->event, NULL);
    return 1;
}

static void CALLBACK pacer_wsl_changed(PTP_CALLBACK_INSTANCE instance, void *value, PTP_WAIT wait, TP_WAIT_RESULT result) {
    (void)instance; (void)wait; (void)result;
    PacerWSLWatch *watch = value;
    AcquireSRWLockExclusive(&watch->lock);
    if (watch->stopped) { ReleaseSRWLockExclusive(&watch->lock); return; }
    int armed = pacer_arm_wsl_watch(watch);
    ReleaseSRWLockExclusive(&watch->lock);
    watch->callback(watch->context, armed);
}

void *pacer_watch_wsl_registrations(void *context, pacer_change_callback callback, void (*closed)(void *)) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, pacer_lxss, 0, KEY_NOTIFY, &key) != ERROR_SUCCESS) return NULL;
    PacerWSLWatch *watch = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*watch));
    if (watch == NULL) { RegCloseKey(key); return NULL; }
    InitializeSRWLock(&watch->lock);
    watch->key = key; watch->context = context; watch->callback = callback; watch->closed = closed;
    watch->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (watch->event != NULL) watch->wait = CreateThreadpoolWait(pacer_wsl_changed, watch, NULL);
    if (watch->wait != NULL && pacer_arm_wsl_watch(watch)) return watch;
    if (watch->wait != NULL) CloseThreadpoolWait(watch->wait);
    if (watch->event != NULL) CloseHandle(watch->event);
    RegCloseKey(key); HeapFree(GetProcessHeap(), 0, watch);
    return NULL;
}

void pacer_close_wsl_registration_watch(void *value) {
    PacerWSLWatch *watch = value;
    AcquireSRWLockExclusive(&watch->lock);
    watch->stopped = 1;
    SetThreadpoolWait(watch->wait, NULL, NULL);
    ReleaseSRWLockExclusive(&watch->lock);
    WaitForThreadpoolWaitCallbacks(watch->wait, TRUE);
    CloseThreadpoolWait(watch->wait);
    RegCloseKey(watch->key); CloseHandle(watch->event);
    watch->closed(watch->context);
    HeapFree(GetProcessHeap(), 0, watch);
}
#endif
