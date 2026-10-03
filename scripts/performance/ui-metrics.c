#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdint.h>

// Counter order: CPU ns, footprint, RSS, physical read/write, logical writes.
int pacer_perf_metrics(uint64_t *values) {
    struct rusage_info_v4 usage = {0};
    mach_timebase_info_data_t scale;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return -1;
    mach_timebase_info(&scale);
    values[0] = (usage.ri_user_time + usage.ri_system_time) * scale.numer / scale.denom;
    values[1] = usage.ri_phys_footprint;
    values[2] = usage.ri_resident_size;
    values[3] = usage.ri_diskio_bytesread;
    values[4] = usage.ri_diskio_byteswritten;
    values[5] = usage.ri_logical_writes;
    return 0;
}
