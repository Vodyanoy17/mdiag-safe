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

If `mongod` is not visible, the report says so and suggests where to run it.

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
