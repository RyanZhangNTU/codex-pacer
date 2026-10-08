// Read-only Darwin process accounting; energy is a system estimate, not battery drain.
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>
#include <stdint.h>

// Darwin CPU counters use Mach time units; energy counters already use nJ.
static uint64_t nanos(uint64_t ticks, mach_timebase_info_data_t scale) {
    __uint128_t value = (__uint128_t)ticks * scale.numer / scale.denom;
    return value > UINT64_MAX ? UINT64_MAX : (uint64_t)value;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    long pid = strtol(argv[1], &end, 10);
    if (!end || *end || pid <= 0 || pid > 2147483647) return 2;
    struct rusage_info_v6 r = {0};
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&r)) return 1;
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) != KERN_SUCCESS || scale.denom == 0) return 1;
    printf("{\"user_ns\":%llu,\"system_ns\":%llu,\"wakeups\":%llu,\"idle_wakeups\":%llu,\"energy_nj\":%llu,\"rss\":%llu,\"disk_read\":%llu,\"disk_write\":%llu,\"timebase_numer\":%u,\"timebase_denom\":%u,\"p_core_user_ns\":%llu,\"p_core_system_ns\":%llu,\"p_core_energy_nj\":%llu}\n",
        (unsigned long long)nanos(r.ri_user_time, scale), (unsigned long long)nanos(r.ri_system_time, scale),
        r.ri_interrupt_wkups, r.ri_pkg_idle_wkups, r.ri_energy_nj,
        r.ri_phys_footprint, r.ri_diskio_bytesread, r.ri_diskio_byteswritten, scale.numer, scale.denom,
        (unsigned long long)nanos(r.ri_user_ptime, scale), (unsigned long long)nanos(r.ri_system_ptime, scale), r.ri_penergy_nj);
    return 0;
}
