// Read-only Darwin process accounting; energy is a system estimate, not battery drain.
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    long pid = strtol(argv[1], &end, 10);
    if (!end || *end || pid <= 0 || pid > 2147483647) return 2;
    struct rusage_info_v6 r = {0};
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&r)) return 1;
    printf("{\"user_ns\":%llu,\"system_ns\":%llu,\"wakeups\":%llu,\"energy_nj\":%llu,\"rss\":%llu,\"disk_read\":%llu,\"disk_write\":%llu}\n",
        r.ri_user_time, r.ri_system_time, r.ri_interrupt_wkups, r.ri_energy_nj,
        r.ri_phys_footprint, r.ri_diskio_bytesread, r.ri_diskio_byteswritten);
    return 0;
}
