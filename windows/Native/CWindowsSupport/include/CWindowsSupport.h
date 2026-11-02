#ifndef PACER_WINDOWS_SUPPORT_H
#define PACER_WINDOWS_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
int pacer_sha256(const uint8_t *bytes, size_t count, uint8_t output[32]);
int pacer_replace_file(const uint16_t *source, const uint16_t *destination);
typedef struct {
    uint64_t volume, file_low, file_high, size, modified, created;
    int regular, directory;
} pacer_file_metadata;
int pacer_read_file_metadata(const uint16_t *path, int follow_links, pacer_file_metadata *metadata);
int pacer_read_credential(const uint16_t *name, uint8_t *bytes, size_t capacity);
int pacer_write_credential(const uint16_t *name, const uint8_t *bytes, size_t count);
int pacer_remove_credential(const uint16_t *name);
int pacer_normalize_ipv6(const char *input, char *output, size_t capacity);
int64_t pacer_read_stdin(uint8_t *bytes, size_t capacity);
int pacer_named_semaphore_exists(const uint16_t *name);
typedef void (*pacer_change_callback)(void *context, int valid);
void *pacer_watch_directory(const uint16_t *path, int names_only, void *context, pacer_change_callback callback);
void pacer_close_directory_watch(void *watch);
int pacer_is_windows_executable(const uint16_t *path);
int pacer_windows_product_matches(const uint16_t *path, const uint16_t *product, const uint16_t *company);
int pacer_harness_registry_path(size_t index, uint16_t *path, size_t capacity);
int pacer_codex_package_path(size_t index, uint16_t *path, size_t capacity);
int pacer_package_path(const uint16_t *family, size_t index, uint16_t *path, size_t capacity);
// Local named pipes only. The caller supplies a registered package root and
// family, or an explicit fixture root with a null family in isolated tests.
void *pacer_pipe_open(const uint16_t *name, const uint16_t *root, const uint16_t *family, uint32_t timeout_ms, int32_t *failure);
// One read and one write may run together. Cancel is safe during either;
// close runs after those calls have returned. -2 = timeout, -3 = cancelled.
int64_t pacer_pipe_read(void *pipe, uint8_t *bytes, size_t capacity, uint32_t timeout_ms);
int64_t pacer_pipe_write(void *pipe, const uint8_t *bytes, size_t count, uint32_t timeout_ms);
void pacer_pipe_cancel(void *pipe);
void pacer_pipe_close(void *pipe);
typedef struct { uint32_t pid; uint32_t parent; uint64_t started; } pacer_process_identity;
// Creation times use the original 100 ns FILETIME ticks, never rounded dates.
int pacer_process_details(uint32_t pid, uint64_t started, pacer_process_identity *identity,
                          uint16_t *image, size_t image_capacity);
int pacer_pipe_peer_identity(void *pipe, pacer_process_identity *identity);
// Metadata only: current-user/session writers of this exact file identity.
// A negative result means ownership could not be established.
int pacer_file_writers(const uint16_t *path, pacer_process_identity *writers, size_t capacity);
int pacer_scoped_file_writers(const uint16_t *home, const uint16_t *path, pacer_process_identity *writers, size_t capacity);
typedef struct { uint64_t file_volume, file_low, file_high, root_volume, root_low, root_high; } pacer_source_file_identity;
int pacer_source_file_stamp(const uint16_t *home, const uint16_t *path, pacer_source_file_identity *stamp);
int pacer_same_directory(const uint16_t *first, const uint16_t *second);
int pacer_process_alive(uint32_t pid, uint64_t started);
// An existing top-level window of the exact current-user/session process.
// activate == 0 only observes availability; this never starts a process.
int pacer_process_window(uint32_t pid, uint64_t started, int activate);
#endif
