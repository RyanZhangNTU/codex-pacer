#include "CWindowsSupport.h"
#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <wchar.h>

int pacer_loopback_listener(uint32_t pid, uint16_t port) {
    DWORD size = 0;
    if (GetExtendedTcpTable(NULL, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) != ERROR_INSUFFICIENT_BUFFER)
        return 0;
    if (size < sizeof(DWORD) || size > 16 * 1024 * 1024) return 0;
    MIB_TCPTABLE_OWNER_PID *table = HeapAlloc(GetProcessHeap(), 0, size);
    if (!table) return 0;
    int found = 0;
    if (GetExtendedTcpTable(table, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) == NO_ERROR) {
        for (DWORD i = 0; i < table->dwNumEntries; ++i) {
            const MIB_TCPROW_OWNER_PID *row = &table->table[i];
            if (row->dwOwningPid == pid && row->dwLocalAddr == htonl(INADDR_LOOPBACK) && ntohs((u_short)row->dwLocalPort) == port) {
                found = 1;
                break;
            }
        }
    }
    HeapFree(GetProcessHeap(), 0, table);
    return found;
}

static void read_string(HKEY key, LPCWSTR name, WCHAR *value, DWORD capacity) {
    DWORD bytes = capacity * sizeof(WCHAR);
    if (RegGetValueW(key, NULL, name, RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ, NULL, value, &bytes) != ERROR_SUCCESS)
        value[0] = 0;
}

int pacer_antigravity_uninstall_entry(uint32_t *index, uint16_t *icon, uint16_t *command, uint32_t capacity) {
    HKEY root;
    if (!index || !icon || !command || !capacity || capacity > 32768 ||
        RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", 0,
                      KEY_ENUMERATE_SUB_KEYS, &root) != ERROR_SUCCESS) return 0;
    int found = 0;
    WCHAR name[256];
    while (!found) {
        DWORD length = 256;
        if (RegEnumKeyExW(root, (*index)++, name, &length, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
        HKEY key;
        if (RegOpenKeyExW(root, name, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) continue;
        WCHAR display[512], publisher[128];
        read_string(key, L"DisplayName", display, 512);
        read_string(key, L"Publisher", publisher, 128);
        if (wcsncmp(display, L"Antigravity", 11) == 0 && wcscmp(publisher, L"Google") == 0) {
            read_string(key, L"DisplayIcon", (WCHAR *)icon, capacity);
            read_string(key, L"UninstallString", (WCHAR *)command, capacity);
            found = 1;
        }
        RegCloseKey(key);
    }
    RegCloseKey(root);
    return found;
}
#endif
