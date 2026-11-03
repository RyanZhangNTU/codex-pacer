#ifndef PACER_WINDOWS_PROCESS_INTERNAL_H
#define PACER_WINDOWS_PROCESS_INTERNAL_H
#if defined(_WIN32)
#include <windows.h>
#include "CWindowsSupport.h"
uint64_t pacer_process_start(HANDLE process);
HANDLE pacer_open_user_process(DWORD pid, DWORD access, uint64_t started);
#endif
#endif
