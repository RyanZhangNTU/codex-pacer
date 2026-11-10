#include "CWindowsSupport.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

/* A short text report for the moment the engine stops on an unhandled exception,
   a damaged heap or abort(). Everything the handlers need is prepared when they are
   installed: the file is already open and the text is built in static storage with
   no heap, locale or loader lock, so a report can still be written after the heap
   is damaged. The file is marked for deletion while the engine runs and kept only
   when a report is written, so an engine that exits or is ended leaves nothing.

   A report holds numbers and module file names: no memory contents, paths,
   arguments or environment. Each address is a module and an offset, and each module
   carries the identity that finds its binary and symbols on a symbol server. */

enum { PACER_REPORT_CAPACITY = 16 * 1024, PACER_REPORT_FRAMES = 48, PACER_REPORT_MODULES = 24, PACER_REPORT_NAME = 64 };

typedef struct {
    ULONG_PTR base;
    DWORD size, time, age;
    int symbols;
    GUID signature;
    char name[PACER_REPORT_NAME], symbol_file[PACER_REPORT_NAME];
} PacerReportModule;

static HANDLE pacer_report_file = INVALID_HANDLE_VALUE;
static volatile LONG pacer_report_written;
static ULONGLONG pacer_report_started;
static ULONG_PTR pacer_report_executable;
static LPTOP_LEVEL_EXCEPTION_FILTER pacer_report_previous;
static char pacer_report_header[1024], pacer_report_executable_name[PACER_REPORT_NAME];
static char pacer_report_text[PACER_REPORT_CAPACITY];
static size_t pacer_report_length;
static PacerReportModule pacer_report_modules[PACER_REPORT_MODULES];
static int pacer_report_module_count;
static CONTEXT pacer_report_context;

static void pacer_report_put(const char *text) {
    while (*text != 0 && pacer_report_length < PACER_REPORT_CAPACITY) pacer_report_text[pacer_report_length++] = *text++;
}
static void pacer_report_number(ULONGLONG value, unsigned base, int digits) {
    char reversed[24]; int count = 0;
    do { reversed[count++] = "0123456789ABCDEF"[value % base]; value /= base; } while (value != 0 && count < 24);
    while (count < digits && count < 24) reversed[count++] = '0';
    while (count > 0 && pacer_report_length < PACER_REPORT_CAPACITY) pacer_report_text[pacer_report_length++] = reversed[--count];
}
static void pacer_report_hex(ULONGLONG value) { pacer_report_put("0x"); pacer_report_number(value, 16, 1); }
static void pacer_report_decimal(ULONGLONG value, int digits) { pacer_report_number(value, 10, digits); }

/* Keeps the file name of a path and only characters that cannot carry anything else. */
static void pacer_report_name(char *output, const char *path, size_t limit) {
    const char *start = path; size_t count = 0;
    for (size_t i = 0; i < limit && path[i] != 0; i++) if (path[i] == '\\' || path[i] == '/') start = path + i + 1;
    for (; start < path + limit && *start != 0 && count < PACER_REPORT_NAME - 1; start++) {
        char c = *start;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') output[count++] = c;
    }
    output[count] = 0;
}

/* The loaded image's own headers name it; asking the loader could wait on its lock. */
static void pacer_report_describe(ULONG_PTR base, PacerReportModule *module) {
    memset(module, 0, sizeof(*module));
    module->base = base;
    __try {
        const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
        if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 || dos->e_lfanew > 4096) __leave;
        const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)(base + (ULONG_PTR)dos->e_lfanew);
        if (headers->Signature != IMAGE_NT_SIGNATURE || headers->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR_MAGIC) __leave;
        module->size = headers->OptionalHeader.SizeOfImage; module->time = headers->FileHeader.TimeDateStamp;
        const IMAGE_DATA_DIRECTORY *exports = &headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
        if (exports->VirtualAddress != 0 && exports->Size >= sizeof(IMAGE_EXPORT_DIRECTORY) && exports->VirtualAddress < module->size) {
            const IMAGE_EXPORT_DIRECTORY *directory = (const IMAGE_EXPORT_DIRECTORY *)(base + exports->VirtualAddress);
            if (directory->Name != 0 && directory->Name < module->size)
                pacer_report_name(module->name, (const char *)(base + directory->Name), module->size - directory->Name);
        }
        const IMAGE_DATA_DIRECTORY *debug = &headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
        if (debug->VirtualAddress != 0 && debug->VirtualAddress < module->size) {
            const IMAGE_DEBUG_DIRECTORY *entries = (const IMAGE_DEBUG_DIRECTORY *)(base + debug->VirtualAddress);
            DWORD count = debug->Size / sizeof(IMAGE_DEBUG_DIRECTORY);
            for (DWORD i = 0; i < count && i < 16; i++) {
                if (entries[i].Type != IMAGE_DEBUG_TYPE_CODEVIEW || entries[i].AddressOfRawData == 0 || entries[i].SizeOfData < 25 ||
                    entries[i].AddressOfRawData >= module->size || entries[i].SizeOfData > module->size - entries[i].AddressOfRawData) continue;
                const BYTE *record = (const BYTE *)(base + entries[i].AddressOfRawData);
                if (memcmp(record, "RSDS", 4) != 0) continue;
                memcpy(&module->signature, record + 4, sizeof(GUID)); memcpy(&module->age, record + 20, sizeof(DWORD));
                pacer_report_name(module->symbol_file, (const char *)record + 24, entries[i].SizeOfData - 24);
                module->symbols = 1; break;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
    if (base == pacer_report_executable && pacer_report_executable_name[0] != 0) memcpy(module->name, pacer_report_executable_name, PACER_REPORT_NAME);
    if (module->name[0] == 0) memcpy(module->name, module->symbol_file[0] != 0 ? module->symbol_file : "unknown", PACER_REPORT_NAME);
}

static void pacer_report_address(ULONG_PTR address, ULONG_PTR base) {
    if (base == 0) { pacer_report_hex(address); return; }
    PacerReportModule *module = NULL;
    for (int i = 0; i < pacer_report_module_count; i++) if (pacer_report_modules[i].base == base) module = &pacer_report_modules[i];
    if (module == NULL && pacer_report_module_count < PACER_REPORT_MODULES) {
        module = &pacer_report_modules[pacer_report_module_count++];
        pacer_report_describe(base, module);
    }
    pacer_report_put(module != NULL ? module->name : "module"); pacer_report_put("+"); pacer_report_hex(address - base);
}

static ULONG_PTR pacer_report_image(ULONG_PTR address) {
    DWORD64 base = 0;
    __try { (void)RtlLookupFunctionEntry(address, &base, NULL); } __except (EXCEPTION_EXECUTE_HANDLER) { base = 0; }
    return (ULONG_PTR)base;
}

/* Walks the stack from the faulting registers with the images' own unwind data. */
static void pacer_report_stack(const CONTEXT *start) {
    pacer_report_context = *start;
    CONTEXT *context = &pacer_report_context;
    pacer_report_put("stack:\n");
    for (int frame = 0; frame < PACER_REPORT_FRAMES; frame++) {
#if defined(_M_ARM64)
        ULONG_PTR address = (ULONG_PTR)context->Pc, stack = (ULONG_PTR)context->Sp;
#else
        ULONG_PTR address = (ULONG_PTR)context->Rip, stack = (ULONG_PTR)context->Rsp;
#endif
        if (address == 0) break;
        DWORD64 base = 0; PRUNTIME_FUNCTION entry = NULL; int walked = 0;
        __try { entry = RtlLookupFunctionEntry(address, &base, NULL); } __except (EXCEPTION_EXECUTE_HANDLER) { entry = NULL; base = 0; }
        pacer_report_put("  "); pacer_report_decimal((ULONGLONG)frame, 1); pacer_report_put(" ");
        pacer_report_address(address, (ULONG_PTR)base); pacer_report_put("\n");
        __try {
            if (entry != NULL) {
                PVOID data = NULL; DWORD64 establisher = 0;
                (void)RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, address, entry, context, &data, &establisher, NULL);
                walked = 1;
            }
#if defined(_M_ARM64)
            else if (frame == 0 && context->Lr != 0 && context->Lr != context->Pc) { context->Pc = context->Lr; walked = 1; }
#else
            else if (stack != 0) { context->Rip = *(const DWORD64 *)stack; context->Rsp += sizeof(DWORD64); walked = 1; }
#endif
        } __except (EXCEPTION_EXECUTE_HANDLER) { walked = 0; }
#if defined(_M_ARM64)
        if (!walked || (ULONG_PTR)context->Sp < stack || ((ULONG_PTR)context->Sp == stack && (ULONG_PTR)context->Pc == address)) break;
#else
        if (!walked || (ULONG_PTR)context->Rsp <= stack) break;
#endif
    }
}

static void pacer_report_register(const char *name, ULONGLONG value) {
    pacer_report_put(" "); pacer_report_put(name); pacer_report_put("="); pacer_report_hex(value);
}
static void pacer_report_registers(const CONTEXT *context) {
    pacer_report_put("registers:");
#if defined(_M_ARM64)
    static const char *const names[29] = {"x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14",
        "x15", "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28"};
    for (int i = 0; i < 29; i++) pacer_report_register(names[i], context->X[i]);
    pacer_report_register("fp", context->Fp); pacer_report_register("lr", context->Lr); pacer_report_register("sp", context->Sp);
    pacer_report_register("pc", context->Pc); pacer_report_register("cpsr", context->Cpsr);
#else
    pacer_report_register("rax", context->Rax); pacer_report_register("rbx", context->Rbx); pacer_report_register("rcx", context->Rcx);
    pacer_report_register("rdx", context->Rdx); pacer_report_register("rsi", context->Rsi); pacer_report_register("rdi", context->Rdi);
    pacer_report_register("rbp", context->Rbp); pacer_report_register("rsp", context->Rsp); pacer_report_register("r8", context->R8);
    pacer_report_register("r9", context->R9); pacer_report_register("r10", context->R10); pacer_report_register("r11", context->R11);
    pacer_report_register("r12", context->R12); pacer_report_register("r13", context->R13); pacer_report_register("r14", context->R14);
    pacer_report_register("r15", context->R15); pacer_report_register("rip", context->Rip); pacer_report_register("eflags", context->EFlags);
#endif
    pacer_report_put("\n");
}

static void pacer_report_write(const char *reason, const EXCEPTION_RECORD *record, const CONTEXT *context) {
    if (pacer_report_file == INVALID_HANDLE_VALUE || InterlockedExchange(&pacer_report_written, 1) != 0) return;
    SYSTEMTIME now; GetSystemTime(&now);
    pacer_report_length = 0; pacer_report_module_count = 0;
    pacer_report_put("Codex Pacer engine crash report 1\ntime: ");
    pacer_report_decimal(now.wYear, 4); pacer_report_put("-"); pacer_report_decimal(now.wMonth, 2); pacer_report_put("-");
    pacer_report_decimal(now.wDay, 2); pacer_report_put("T"); pacer_report_decimal(now.wHour, 2); pacer_report_put(":");
    pacer_report_decimal(now.wMinute, 2); pacer_report_put(":"); pacer_report_decimal(now.wSecond, 2); pacer_report_put("Z\n");
    pacer_report_put(pacer_report_header);
    pacer_report_put("process: "); pacer_report_decimal(GetCurrentProcessId(), 1); pacer_report_put(" thread: ");
    pacer_report_decimal(GetCurrentThreadId(), 1); pacer_report_put(" running: ");
    pacer_report_decimal((GetTickCount64() - pacer_report_started) / 1000, 1); pacer_report_put(" s\nreason: ");
    pacer_report_put(reason); pacer_report_put("\n");
    if (record != NULL) {
        pacer_report_put("exception: "); pacer_report_hex(record->ExceptionCode); pacer_report_put(" flags: ");
        pacer_report_hex(record->ExceptionFlags);
        DWORD parameters = record->NumberParameters < EXCEPTION_MAXIMUM_PARAMETERS ? record->NumberParameters : EXCEPTION_MAXIMUM_PARAMETERS;
        if (parameters > 0) pacer_report_put(" parameters:");
        for (DWORD i = 0; i < parameters; i++) { pacer_report_put(" "); pacer_report_hex(record->ExceptionInformation[i]); }
        pacer_report_put("\n");
        if ((record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION || record->ExceptionCode == EXCEPTION_IN_PAGE_ERROR) && parameters >= 2) {
            pacer_report_put(record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION ? "detail: access violation " : "detail: page read failure ");
            pacer_report_put(record->ExceptionInformation[0] == 0 ? "reading " : record->ExceptionInformation[0] == 1 ? "writing " : "executing ");
            pacer_report_hex(record->ExceptionInformation[1]); pacer_report_put("\n");
        }
        pacer_report_put("address: ");
        pacer_report_address((ULONG_PTR)record->ExceptionAddress, pacer_report_image((ULONG_PTR)record->ExceptionAddress));
        pacer_report_put("\n");
    }
    if (context != NULL) { pacer_report_registers(context); pacer_report_stack(context); }
    pacer_report_put("modules:\n");
    for (int i = 0; i < pacer_report_module_count; i++) {
        const PacerReportModule *module = &pacer_report_modules[i];
        pacer_report_put("  "); pacer_report_put(module->name); pacer_report_put(" time: "); pacer_report_number(module->time, 16, 8);
        pacer_report_put(" size: "); pacer_report_number(module->size, 16, 1);
        if (module->symbols) {
            const BYTE *tail = module->signature.Data4;
            pacer_report_put(" symbols: "); pacer_report_put(module->symbol_file); pacer_report_put(" ");
            pacer_report_number(module->signature.Data1, 16, 8); pacer_report_number(module->signature.Data2, 16, 4);
            pacer_report_number(module->signature.Data3, 16, 4);
            for (int j = 0; j < 8; j++) pacer_report_number(tail[j], 16, 2);
            pacer_report_number(module->age, 16, 1);
        }
        pacer_report_put("\n");
    }
    FILE_DISPOSITION_INFO keep = {FALSE};
    DWORD written = 0;
    (void)SetFileInformationByHandle(pacer_report_file, FileDispositionInfo, &keep, sizeof(keep));
    (void)WriteFile(pacer_report_file, pacer_report_text, (DWORD)pacer_report_length, &written, NULL);
    (void)FlushFileBuffers(pacer_report_file);
}

static LONG WINAPI pacer_report_unhandled(EXCEPTION_POINTERS *info) {
    if (info != NULL) pacer_report_write("unhandled exception", info->ExceptionRecord, info->ContextRecord);
    return pacer_report_previous != NULL ? pacer_report_previous(info) : EXCEPTION_CONTINUE_SEARCH;
}
/* Windows ends a process with a damaged heap without asking the unhandled-exception filter. */
static LONG CALLBACK pacer_report_first_chance(EXCEPTION_POINTERS *info) {
    if (info != NULL && info->ExceptionRecord != NULL && info->ExceptionRecord->ExceptionCode == (DWORD)0xC0000374)
        pacer_report_write("heap corruption", info->ExceptionRecord, info->ContextRecord);
    return EXCEPTION_CONTINUE_SEARCH;
}
/* abort() ends the process with a fail-fast that no exception handler sees. */
static void pacer_report_abort(int signal_number) {
    (void)signal_number;
    CONTEXT context; RtlCaptureContext(&context);
    pacer_report_write("abort", NULL, &context);
}

int pacer_crash_report_install(const uint16_t *file, const char *header) {
    if (file == NULL || header == NULL || pacer_report_file != INVALID_HANDLE_VALUE) return 0;
    typedef LONG (WINAPI *PacerGetVersion)(OSVERSIONINFOW *);
    OSVERSIONINFOW version = {0}; version.dwOSVersionInfoSize = sizeof(version);
    PacerGetVersion get_version = (PacerGetVersion)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    if (get_version != NULL) (void)get_version(&version);
    DWORD revision = 0, bytes = sizeof(revision);
    (void)RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", L"UBR", RRF_RT_REG_DWORD, NULL, &revision, &bytes);
    char lines[512]; size_t count = 0;
    for (; header[count] != 0 && count < sizeof(lines) - 1; count++) {
        char c = header[count];
        lines[count] = c == '\n' || (c >= 32 && c < 127) ? c : '?';
    }
    lines[count] = 0;
    int length = snprintf(pacer_report_header, sizeof(pacer_report_header), "%s%swindows: %lu.%lu.%lu.%lu\n", lines,
                          count > 0 && lines[count - 1] != '\n' ? "\n" : "", version.dwMajorVersion, version.dwMinorVersion,
                          version.dwBuildNumber, revision);
    if (length < 0 || length >= (int)sizeof(pacer_report_header)) return 0;
    WCHAR image[1024]; char narrow[1024];
    DWORD image_length = GetModuleFileNameW(NULL, image, 1024);
    for (DWORD i = 0; i <= image_length && i < 1023; i++) narrow[i] = image[i] < 128 ? (char)image[i] : '_';
    narrow[image_length < 1023 ? image_length : 1023] = 0;
    pacer_report_name(pacer_report_executable_name, narrow, sizeof(narrow));
    pacer_report_executable = (ULONG_PTR)GetModuleHandleW(NULL);
    pacer_report_started = GetTickCount64();
    HANDLE opened = CreateFileW((LPCWSTR)file, GENERIC_WRITE | DELETE, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, NULL);
    if (opened == INVALID_HANDLE_VALUE) return 0;
    FILE_DISPOSITION_INFO remove = {TRUE};
    if (!SetFileInformationByHandle(opened, FileDispositionInfo, &remove, sizeof(remove))) {
        CloseHandle(opened); DeleteFileW((LPCWSTR)file); return 0;
    }
    pacer_report_file = opened;
    pacer_report_previous = SetUnhandledExceptionFilter(pacer_report_unhandled);
    (void)AddVectoredExceptionHandler(0, pacer_report_first_chance);
    (void)signal(SIGABRT, pacer_report_abort);
    return 1;
}
#else
int pacer_crash_report_install(const uint16_t *file, const char *header) { return 0; }
#endif
