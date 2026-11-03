#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include "CWindowsSupport.h"

int pacer_read_file_metadata(const uint16_t *path, int follow_links, pacer_file_metadata *metadata) {
    if (!path || !metadata) return 0;
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS;
    if (!follow_links) flags |= FILE_FLAG_OPEN_REPARSE_POINT;
    HANDLE file = CreateFileW((LPCWSTR)path, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, flags, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    FILE_ID_INFO identity;
    FILE_STANDARD_INFO standard;
    FILE_BASIC_INFO basic;
    int valid = GetFileType(file) == FILE_TYPE_DISK &&
        GetFileInformationByHandleEx(file, FileIdInfo, &identity, sizeof(identity)) &&
        GetFileInformationByHandleEx(file, FileStandardInfo, &standard, sizeof(standard)) &&
        GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic)) && standard.EndOfFile.QuadPart >= 0;
    if (valid) {
        memset(metadata, 0, sizeof(*metadata));
        metadata->volume = identity.VolumeSerialNumber;
        memcpy(&metadata->file_low, identity.FileId.Identifier, 8);
        memcpy(&metadata->file_high, identity.FileId.Identifier + 8, 8);
        metadata->size = (uint64_t)standard.EndOfFile.QuadPart;
        metadata->modified = (uint64_t)basic.LastWriteTime.QuadPart;
        metadata->created = (uint64_t)basic.CreationTime.QuadPart;
        int link = !follow_links && (basic.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
        metadata->directory = !link && standard.Directory;
        metadata->regular = !link && !standard.Directory;
    }
    CloseHandle(file);
    return valid;
}
