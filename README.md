# mdiag-safe

An anonymized, relative-only health report for hosts, VMs, containers and
Kubernetes pods that run MongoDB (`mongod` / `mongos`).

It is inspired by MongoDB's `mdiag.sh`, but built for situations where the
report must be shared without exposing the environment:

- **No names.** No hostnames or pod names, usernames, IPs, MACs, paths, device
  names, mount points, interface names, config values, timestamps or ticket
  references. Things are labelled generically: `disk1`, `fs1`, `mongo1`.
- **No absolute values.** No sizes, core or RAM counts, byte numbers, ports or
  PIDs. Only percentage bands (`<10%`, `10-25%`, `25-50%`, `50-75%`, `75-90%`,
  `90-100%`, `>100%`), coarse time bands, `none/few/many` counts, booleans, and
  `[OK]` / `[WARN]` / `[INFO]` checks against generic MongoDB recommendations.
- **Read-only and offline.** No self-update, no network calls, nothing written
  to disk. The report goes to stdout.

The result still tells you whether the system is healthy and where it deviates
from MongoDB production recommendations, but it does not let the reader size
or identify the target environment.

## Requirements

- Linux (bare metal, VM, container or pod; cgroup v1 and v2)
- bash 4 or later
- `awk`, `sed`, `grep` (standard on practically every image)
- Root is recommended. Without it some fields show `n/a`.

Optional tools are used when present (`timedatectl`, `chronyc`, `iptables`,
`dmesg`, `getenforce`, `systemd-detect-virt`), and every section degrades
gracefully when they are missing.

## Usage

```bash
sudo bash mdiag-safe.sh > report.txt
sudo bash mdiag-safe.sh --sample 30 > report.txt   # longer measurement window
```

| Option          | Meaning                                              |
|-----------------|------------------------------------------------------|
| `--sample N`    | Measurement window in seconds (1-300, default 5)     |
| `--help`, `-h`  | Show usage                                           |

Exit codes: `0` normal, `1` bad arguments or unsupported OS, `3` the anonymity
audit had to mask data (review the report before sharing).

### Containers and Kubernetes

Run the script inside the container that runs `mongod` (or one that shares its
process namespace). In a container, `/proc/meminfo`, `nproc`, load average and
`/proc/stat` describe the host, so the script measures against the cgroup
limits instead and labels host-level numbers `(host-wide)`.

```bash
kubectl cp mdiag-safe.sh <pod>:/tmp/mdiag-safe.sh
kubectl exec <pod> -- bash /tmp/mdiag-safe.sh > report.txt
```

```
docker cp mdiag-safe.sh oplog:/tmp/mdiag-safe.sh
docker exec oplog bash /tmp/mdiag-safe.sh > report.txt
```

If `mongod` is not visible, the report says so and suggests where to run it.

## Example output

Real output from a Docker container (memory limit and CPU quota set) running a
stand-in `mongod` process. Everything you see is everything the report
contains. There are no names, addresses, paths or absolute sizes.

```text
MongoDB host health report (anonymized, relative values only)
tool: mdiag-safe 2.0.0   run id: 73eae479006e
legend: [OK] meets generic recommendation, [WARN] deviates, [INFO] informational

== Summary ==
  checks                                   37 OK, 7 WARN, 1 INFO
  anonymity audit                          clean (nothing had to be masked)
  items needing attention:
    - vm.swappiness : above recommended
    - tcp_keepalive_time : above recommended
    - THP enabled : mode: always
    - disk1 read-ahead : far above recommended
    - disk2 read-ahead : far above recommended
    - [mongo1] TLS/SSL enabled : no
    - [mongo1] data on dedicated volume : no - container writable layer

== Platform ==
  environment type                         container
  underlying host virtualized              no / undetectable
  cgroup version                           v2
  memory limit configured                  yes
  CPU limit configured (quota)             yes
  memory limit / host RAM                  <10%
  CPU limit / host cores                   <10%
  distro family                            rhel (major 8)
  kernel (major.minor)                     7.0
  architecture class                       arm64
  host time since boot                     1 day - 1 week

== CPU features ==
  AVX supported                            n/a (non-x86)
  CPU frequency governor                   not exposed (VM/container/fixed freq)
  SMT / hyperthreading                     n/a

== CPU and memory (relative) ==
  load average / cores (1m) (host-wide)    <10%
  load average / cores (5m) (host-wide)    <10%
  container CPU used / effective limit     [OK] <10%
  CPU throttled periods                    [OK] <10%
  CPU user (host-wide)                     <10%
  CPU system/irq (host-wide)               <10%
  CPU iowait (host-wide)                   <10%
  CPU steal (host-wide)                    [OK] <10%
  container working set / memory limit     [OK] <10%
  container OOM kills                      [OK] none
  host memory available (host-wide)        25-50%
  host page cache / total (host-wide)      25-50%
  host dirty pages / total (host-wide)     <10%
  swap in use / total (host-wide)          [OK] <10%
  NUMA (host-wide)                         single node / none

== Pressure stalls (PSI, share of time stalled, 60s window) ==
  container CPU some                       [OK] <10%
  container memory some                    [OK] <10%
  container memory full                    [OK] <10%
  container I/O some                       [OK] <10%
  container I/O full                       [OK] <10%
  host-wide CPU some                       [OK] <10%
  host-wide memory some                    [OK] <10%
  host-wide memory full                    [OK] <10%
  host-wide I/O some                       [OK] <10%
  host-wide I/O full                       [OK] <10%

== Memory activity during sample (host-wide) ==
  swap in/out activity                     [OK] none
  major page faults                        [OK] low
  direct reclaim (allocation stalls)       [OK] none
  free memory in large blocks              25-50%

== Kernel settings vs. MongoDB production recommendations - host kernel ==
  vm.swappiness                            [WARN] above recommended
  vm.zone_reclaim_mode                     n/a
  vm.overcommit_memory                     [OK] heuristic/always (not strict)
  vm.max_map_count                         [OK] meets recommendation
  tcp_keepalive_time                       [WARN] above recommended
  THP enabled                              [WARN] mode: always
  THP defrag                               madvise
  clocksource                              [OK] fast (arch_sys_counter)
  SELinux                                  not present / not visible

== Capacity headroom (used / limit) ==
  open files (system-wide)                 [OK] <10%
  threads / min(threads-max,pid_max)       [OK] <10%
  container PIDs limit                     none
  TCP sockets / ephemeral port range       [OK] <10%
  conntrack table used                     [OK] <10%
  net.core.somaxconn                       [OK] meets recommendation
  vm.dirty_background_ratio                [OK] at/below recommended
  vm.dirty_ratio                           [OK] at/below recommended

== Time synchronization ==
  clock                                    inherited from host (not checkable from container)

== Block devices (anonymized) - host-visible devices; may not map to the data volume ==
  disk1 type                               rotational flag set
  disk1 scheduler                          mq-deadline
  disk1 read-ahead                         [WARN] far above recommended
  disk1 busy (sample)                      [OK] <10%
  disk2 type                               rotational flag set
  disk2 scheduler                          mq-deadline
  disk2 read-ahead                         [WARN] far above recommended
  disk2 busy (sample)                      [OK] <10%

== Filesystems visible to this environment (anonymized) ==
  fs1 type                                 overlay
  fs1 role                                 container writable layer
  fs1 space used                           <10%
  fs2 type                                 virtiofs
  fs2 space used                           10-25%

== Network posture (no addresses) ==
  packet filtering                         not checkable from container (CNI / host / network policy)

== MongoDB processes ==

  [mongo1] role                            mongod
  [mongo1] config file used                yes
  [mongo1] version (major.minor)           n/a
  [mongo1] process age                     <1 hour
  [mongo1] CPU lifetime avg / eff. CPUs    <10%
  [mongo1] RSS / effective memory          [OK] <10%
  [mongo1] fd used / limit                 [OK] <10%
  [mongo1] nofile limit                    [OK] meets recommendation
  [mongo1] nproc limit                     [OK] meets recommendation
  [mongo1] cgroup memory cap / host RAM    <10%
  [mongo1] authorization enabled           [OK] yes
  [mongo1] TLS/SSL enabled                 [WARN] no
  [mongo1] replica set member              no
  [mongo1] sharded cluster role            no
  [mongo1] storage engine                  default
  [mongo1] listen scope                    n/a
  [mongo1] data fs type                    overlay
  [mongo1] data on dedicated volume        [WARN] no - container writable layer
  [mongo1] data fs space used              [OK] <10%
  [mongo1] data fs inodes used             <10%
  [mongo1] data fs noatime                 [INFO] no
  [mongo1] data disk                       n/a (virtual/network filesystem)

  mongod/mongos process count class        single

== Kernel log events (counts reported as none/few/many) ==
  dmesg                                    n/a (not permitted / not available in container)

-- end of report --
```

Reading it: the summary lists the WARN items to look at first. Values in
square brackets are checks against generic MongoDB recommendations; lines
without a bracket are informational ratios. In this example the WARNs are host
kernel tuning (swappiness, keepalive, THP), a large read-ahead on the host
disks, TLS not configured, and the data directory sitting on the container's
writable layer instead of a dedicated volume.

## What it reports

| Section                | Contents |
|------------------------|----------|
| Summary                | OK/WARN/INFO counts, list of WARN items, anonymity audit result, random run ID |
| Platform               | environment type (bare-metal / VM / container / pod), cgroup version, limit configured yes/no, limits relative to host, distro family, kernel major.minor, architecture class, time since boot (band) |
| CPU features           | AVX (needed by MongoDB 5.0+), frequency governor, SMT |
| CPU and memory         | load per core, CPU user/system/iowait/steal over the sample window, container CPU against its limit, CPU throttling, memory working set against limit, OOM kills, swap use, page cache, dirty pages, NUMA |
| Pressure stalls (PSI) | CPU, memory and I/O stall share, per container and host-wide |
| Memory activity        | swap in/out, major page faults, direct reclaim, free-memory fragmentation |
| Kernel settings        | swappiness, zone reclaim, overcommit, `max_map_count`, TCP keepalive, THP, clocksource, SELinux |
| Capacity headroom      | open files, threads, PIDs, ephemeral ports, conntrack, `somaxconn`, dirty ratios, all as used/limit |
| Time synchronization   | sync daemon type, synchronized yes/no |
| Block devices and filesystems | type, scheduler, read-ahead, busy % per disk; filesystem type and space used |
| Network posture        | packet filtering present or not (no addresses) |
| MongoDB processes      | role, version (major.minor), age, CPU and RSS against effective limits, fd and nofile/nproc limits, cgroup cap, NUMA interleave, auth / TLS / replica set / sharding flags (booleans only), listen scope (loopback / all interfaces / specific), data filesystem type, space, inodes, noatime, data volume vs container layer, data disk behind the data path |
| Kernel log events      | OOM, I/O errors, machine checks, hung tasks, segfaults as none/few/many |

## How anonymity is enforced

1. The script never prints raw values. It converts to bands, enums or booleans
   at the point of collection.
2. A final scrub pass masks anything that still looks like an IP, a MAC, the
   host's hostname, or the current user name.
3. An audit compares the output before and after scrubbing. If anything was
   masked the summary says so and the script exits with code `3`.

What remains visible by design: distro family and major version, kernel
major.minor, architecture class, MongoDB major.minor, and which kernel settings
deviate from recommendations. Edit the script if you want those coarser or
removed.

## Notes and limitations

- Thresholds are generic MongoDB production-notes values, not site-specific
  targets. Adjust them in the script if your standards differ.
- Inside a container the disk list shows host-visible devices and the report
  marks it as such. The data disk section follows the actual data path.
- Clock sync and firewall state cannot be checked from inside a container and
  are reported as such.
- One sample window gives a snapshot, not a trend. Use `--sample` for a longer
  window.

## Disclaimer

Provided as is, without warranty. Review and test before running in production.
It is read-only, but it does read system files and run a few diagnostic
commands.

## License

MIT, see [LICENSE](LICENSE).
