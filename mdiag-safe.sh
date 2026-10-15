#!/bin/bash
#
# mdiag-safe.sh: anonymized, relative-only MongoDB host/container health report
#
# Works on: bare-metal, virtual machines, containers (Docker/Podman/LXC/...)
# and Kubernetes pods; cgroup v1 and v2; run on the host or inside the
# container/pod that runs (or shares a process namespace with) mongod/mongos.
#
# Design rules
#   1. No names: no hostnames/pod names, usernames, IPs, MACs, paths, device
#      names, mount points, interface names, config values, timestamps or
#      ticket refs. Things are labelled generically (disk1, fs1, mongo1, ...).
#   2. No absolute values: no sizes, core/RAM counts, byte numbers, ports,
#      PIDs or clock times. Only percentages in coarse bands, enums, booleans
#      and pass/fail checks against generic MongoDB recommendations.
#   3. Read-only and offline: no self-update, no network calls, nothing is
#      written to disk. The report goes to stdout.
#   4. Container-aware: when running in a container, utilization is computed
#      against the cgroup limits (what the workload really gets), and
#      host-wide numbers are labelled "(host-wide)".
#   5. Final scrub pass masks anything that still looks like an IP/MAC or
#      matches this host's hostname/user.
#
# Usage:  sudo bash mdiag-safe.sh > report.txt
#         (root is recommended; without it some fields show "n/a")

export LC_ALL=C
PATH="$PATH${PATH+:}/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"
version="2.0.0"

if [ "$(uname -s)" != "Linux" ]; then
	echo "mdiag-safe.sh: ERROR: only Linux is supported" >&2
	exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
	echo "mdiag-safe.sh: ERROR: bash >= 4 required" >&2
	exit 1
fi

SAMPLE_SECS=5
U60=1152921504606846976      # 2^60: anything >= this is "unlimited" in cgroup files

# ---------------------------------------------------------------- helpers

have() { command -v "$1" >/dev/null 2>&1; }
rd()   { cat "$1" 2>/dev/null; }
isnum(){ [[ "$1" =~ ^[0-9]+$ ]]; }

hdr() { printf '\n== %s ==\n' "$1"; }
row() { printf '  %-40s %s\n' "$1" "$2"; }
chk() { printf '  %-40s [%s] %s\n' "$1" "$2" "$3"; }   # name, OK|WARN|INFO, text

# integer percent -> coarse band (never the exact number)
band() {
	local v="$1"
	isnum "$v" || { echo "n/a"; return; }
	if   [ "$v" -lt 10 ];  then echo "<10%"
	elif [ "$v" -lt 25 ];  then echo "10-25%"
	elif [ "$v" -lt 50 ];  then echo "25-50%"
	elif [ "$v" -lt 75 ];  then echo "50-75%"
	elif [ "$v" -lt 90 ];  then echo "75-90%"
	elif [ "$v" -le 100 ]; then echo "90-100%"
	else echo ">100%"
	fi
}
# CPU limit in cores x100 -> coarse whole-core bucket (upper bound inclusive)
corebucket() {
	local v="$1"
	isnum "$v" || { echo "n/a"; return; }
	if   [ "$v" -le 100 ];  then echo "<=1 core"
	elif [ "$v" -le 200 ];  then echo "1-2 cores"
	elif [ "$v" -le 400 ];  then echo "2-4 cores"
	elif [ "$v" -le 800 ];  then echo "4-8 cores"
	elif [ "$v" -le 1600 ]; then echo "8-16 cores"
	else echo ">16 cores"
	fi
}
# memory limit in KiB -> coarse GiB bucket (upper bound inclusive)
membucket() {
	local v="$1"
	isnum "$v" || { echo "n/a"; return; }
	local m=$(( v / 1024 ))   # MiB
	if   [ "$m" -le 512 ];   then echo "<=0.5 GiB"
	elif [ "$m" -le 1024 ];  then echo "0.5-1 GiB"
	elif [ "$m" -le 2048 ];  then echo "1-2 GiB"
	elif [ "$m" -le 4096 ];  then echo "2-4 GiB"
	elif [ "$m" -le 8192 ];  then echo "4-8 GiB"
	elif [ "$m" -le 16384 ]; then echo "8-16 GiB"
	elif [ "$m" -le 32768 ]; then echo "16-32 GiB"
	elif [ "$m" -le 65536 ]; then echo "32-64 GiB"
	else echo ">64 GiB"
	fi
}
# is a band "high" (>=75%)?
band_high() { case "$1" in "75-90%"|"90-100%"|">100%") return 0;; esac; return 1; }

ageband() {
	local s="$1"
	isnum "$s" || { echo "n/a"; return; }
	if   [ "$s" -lt 3600 ];     then echo "<1 hour"
	elif [ "$s" -lt 86400 ];    then echo "1 hour - 1 day"
	elif [ "$s" -lt 604800 ];   then echo "1 day - 1 week"
	elif [ "$s" -lt 2592000 ];  then echo "1 week - 1 month"
	elif [ "$s" -lt 15552000 ]; then echo "1 - 6 months"
	else echo ">6 months"
	fi
}

countband() {
	if   [ "$1" -eq 0 ]; then echo "none"
	elif [ "$1" -le 5 ]; then echo "few"
	else echo "many"
	fi
}

# a/b*100 as integer (empty if b is 0/invalid)
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0>0) printf "%d", a*100/b }'; }

# status line from a band: WARN if high
chk_band() { # name, band
	if band_high "$2"; then chk "$1" WARN "$2"; else chk "$1" OK "$2"; fi
}

# ---------------------------------------------------------------- environment

IN_CONTAINER=n
K8S=n
CGV=none
HOST_CORES=1
EFF_MEM_KB=0         # effective memory (min of host RAM and cgroup limit), kB
EFF_CPU_X100=100     # effective CPUs * 100
MEM_LIMITED=n
CPU_LIMITED=n
NUMA_MULTI=n

detect_env() {
	if [ -n "$KUBERNETES_SERVICE_HOST" ] || [ -d /var/run/secrets/kubernetes.io ]; then
		K8S=y; IN_CONTAINER=y
	fi
	if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then IN_CONTAINER=y; fi
	if grep -qaE 'docker|kubepods|containerd|libpod|crio|lxc' /proc/1/cgroup 2>/dev/null; then IN_CONTAINER=y; fi
	if tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then IN_CONTAINER=y; fi
	if have systemd-detect-virt; then
		local c; c="$(systemd-detect-virt -c 2>/dev/null)"
		[ -n "$c" ] && [ "$c" != none ] && IN_CONTAINER=y
	fi

	if [ -f /sys/fs/cgroup/cgroup.controllers ]; then CGV=v2
	elif [ -d /sys/fs/cgroup/memory ] || [ -d /sys/fs/cgroup/cpu ] || [ -d /sys/fs/cgroup/cpu,cpuacct ]; then CGV=v1
	fi

	HOST_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
	isnum "$HOST_CORES" && [ "$HOST_CORES" -gt 0 ] || HOST_CORES="$(nproc 2>/dev/null || echo 1)"

	EFF_MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
	MEM_LIMITED=n; CPU_LIMITED=n
	if [ "$IN_CONTAINER" = y ] && [ "$CGV" != none ]; then
		cg_dirs self
		local ml cl
		if [ -n "$MEMDIR" ] && [ -d "$MEMDIR" ]; then
			ml="$(cg_mem_limit)"
			if isnum "$ml" && [ $(( ml / 1024 )) -lt "$EFF_MEM_KB" ]; then
				EFF_MEM_KB=$(( ml / 1024 )); MEM_LIMITED=y
			fi
		fi
		# honour cpuset (nproc) and quota, whichever is smaller
		local aff; aff="$(nproc 2>/dev/null)"
		isnum "$aff" && EFF_CPU_X100=$(( aff * 100 )) || EFF_CPU_X100=$(( HOST_CORES * 100 ))
		if [ -n "$CPUDIR" ] && [ -d "$CPUDIR" ]; then
			cl="$(cg_cpu_limit_x100)"
			if isnum "$cl" && [ "$cl" -lt "$EFF_CPU_X100" ]; then
				EFF_CPU_X100="$cl"; CPU_LIMITED=y
			fi
		fi
	else
		EFF_CPU_X100=$(( HOST_CORES * 100 ))
	fi
}

# ---------------------------------------------------------------- cgroup helpers
# cg_dirs <pid|self> sets MEMDIR MEMROOT CPUDIR CPUROOT

cg_dirs() {
	local pid="$1" p cgroup_file
	MEMDIR=""; CPUDIR=""; MEMROOT=""; CPUROOT=""
	cgroup_file="/proc/$pid/cgroup"
	case "$CGV" in
	v2)
		p=""
		while IFS=: read -r _controllers _subsys path; do
			[ -n "$path" ] || continue
			path="${path%% *}"
			[ "$path" = "/" ] && path=""
			p="$path"
			break
		done < "$cgroup_file" 2>/dev/null
		MEMROOT=/sys/fs/cgroup; CPUROOT=/sys/fs/cgroup
		MEMDIR="$MEMROOT${p:-/}"; [ -d "$MEMDIR" ] || MEMDIR="$MEMROOT"
		CPUDIR="$MEMDIR"
		;;
	v1)
		MEMROOT=/sys/fs/cgroup/memory
		CPUROOT=/sys/fs/cgroup/cpu
		[ -d /sys/fs/cgroup/cpu,cpuacct ] && CPUROOT=/sys/fs/cgroup/cpu,cpuacct
		p="$(awk -F: '$2 ~ /(^|,)memory(,|$)/{print $3; exit}' "$cgroup_file" 2>/dev/null)"
		p="${p:-/}"
		MEMDIR="$MEMROOT${p%/}"; [ -d "$MEMDIR" ] || MEMDIR="$MEMROOT"
		p="$(awk -F: '$2 ~ /(^|,)cpu(,|$)/{print $3; exit}' "$cgroup_file" 2>/dev/null)"
		p="${p:-/}"
		CPUDIR="$CPUROOT${p%/}"; [ -d "$CPUDIR" ] || CPUDIR="$CPUROOT"
		;;
	*)
		MEMDIR=""; CPUDIR=""
		;;
	esac
}

# minimum numeric value of <file> in <dir> and its ancestors up to <root>
cg_min_num() {
	local d="$1" f="$2" root="$3" v min=""
	while [ ${#d} -ge ${#root} ]; do
		v="$(rd "$d/$f")"
		if isnum "$v" && [ "$v" -lt "$U60" ]; then
			if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min="$v"; fi
		fi
		d="${d%/*}"
	done
	echo "$min"
}

cg_mem_limit() {
	case "$CGV" in
		v2) cg_min_num "$MEMDIR" memory.max "$MEMROOT";;
		v1) cg_min_num "$MEMDIR" memory.limit_in_bytes "$MEMROOT";;
	esac
}

cg_mem_workingset() {   # bytes (usage minus inactive file cache, like kubelet)
	local u i
	case "$CGV" in
		v2) u="$(rd "$MEMDIR/memory.current")"
		    i="$(awk '/^inactive_file /{print $2}' "$MEMDIR/memory.stat" 2>/dev/null)";;
		v1) u="$(rd "$MEMDIR/memory.usage_in_bytes")"
		    i="$(awk '/^total_inactive_file /{print $2}' "$MEMDIR/memory.stat" 2>/dev/null)";;
	esac
	isnum "$u" || return
	isnum "$i" || i=0
	[ "$i" -gt "$u" ] && i="$u"
	echo $(( u - i ))
}

cg_oom_kills() {
	case "$CGV" in
		v2) awk '/^oom_kill /{print $2}' "$MEMDIR/memory.events" 2>/dev/null;;
		v1) awk '/^oom_kill /{print $2}' "$MEMDIR/memory.oom_control" 2>/dev/null;;
	esac
}

cg_cpu_limit_x100() {
	local d="$CPUDIR" min="" q p v
	if [ -z "$d" ] || [ ! -d "$d" ]; then
		echo ""
		return
	fi
	while [ ${#d} -ge ${#CPUROOT} ]; do
		v=""
		if [ "$CGV" = v2 ]; then
			read -r q p < <(rd "$d/cpu.max")
			if [ "$q" = max ] || [ -z "$q" ] || [ -z "$p" ]; then
				q=""; p=""
			fi
		else
			q="$(rd "$d/cpu.cfs_quota_us")"; p="$(rd "$d/cpu.cfs_period_us")"
		fi
		if isnum "$q" && isnum "$p" && [ "$p" -gt 0 ] && [ "$q" -gt 0 ]; then
			v=$(( q * 100 / p ))
			if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min="$v"; fi
		fi
		d="${d%/*}"
	done
	echo "$min"
}

cg_cpu_usage_usec() {
	case "$CGV" in
		v2) awk '/^usage_usec /{print $2}' "$CPUDIR/cpu.stat" 2>/dev/null;;
		v1) local n; n="$(rd "$CPUDIR/cpuacct.usage")"; isnum "$n" && echo $(( n / 1000 ));;
	esac
}

cg_throttle() {   # "periods throttled"
	awk '/^nr_periods /{p=$2} /^nr_throttled /{t=$2} END{ if (p!="") print p, t }' "$CPUDIR/cpu.stat" 2>/dev/null
}

# ---------------------------------------------------------------- sections

s_platform() {
	hdr "Platform"
	local id="" ver="" k kind
	if [ -r /etc/os-release ]; then
		id="$(. /etc/os-release; echo "$ID")"
		ver="$(. /etc/os-release; echo "${VERSION_ID%%.*}")"
	fi
	k="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"

	if   [ "$K8S" = y ];            then kind="container (Kubernetes pod)"
	elif [ "$IN_CONTAINER" = y ];   then kind="container"
	elif have systemd-detect-virt && [ "$(systemd-detect-virt -v 2>/dev/null)" != none ] && [ -n "$(systemd-detect-virt -v 2>/dev/null)" ]; then
		kind="virtual machine"
	elif grep -q '^flags.*hypervisor' /proc/cpuinfo 2>/dev/null; then kind="virtual machine"
	else kind="bare-metal (or undetectable)"
	fi
	row "environment type" "$kind"
	if [ "$IN_CONTAINER" = y ]; then
		if grep -q '^flags.*hypervisor' /proc/cpuinfo 2>/dev/null; then
			row "underlying host virtualized" "yes"
		else
			row "underlying host virtualized" "no / undetectable"
		fi
		row "cgroup version" "$CGV"
		row "memory limit configured" "$([ "$MEM_LIMITED" = y ] && echo yes || echo no)"
		if [ "$MEM_LIMITED" != y ] && [ "$(tr -d '\0' < /proc/1/comm 2>/dev/null)" = systemd ]; then
			chk "memory limit visibility" INFO "init system (systemd) is PID 1; a runtime limit may be set but not visible/enforced in this cgroup"
		fi
		row "CPU limit configured (quota)" "$([ "$CPU_LIMITED" = y ] && echo yes || echo no)"
		if [ "$MEM_LIMITED" = y ]; then
			row "memory limit" "$(membucket "$EFF_MEM_KB")"
		fi
		if [ "$CPU_LIMITED" = y ]; then
			row "CPU limit (quota)" "$(corebucket "$EFF_CPU_X100")"
		fi
	fi
	if [ "$IN_CONTAINER" = y ] && [ "$CGV" != none ]; then
		local iol=no
		case "$CGV" in
			v2) grep -q . "$MEMDIR/io.max" 2>/dev/null && iol=yes;;
			v1) grep -qv ' 0$' /sys/fs/cgroup/blkio/blkio.throttle.read_bps_device /sys/fs/cgroup/blkio/blkio.throttle.write_bps_device /sys/fs/cgroup/blkio/blkio.throttle.read_iops_device /sys/fs/cgroup/blkio/blkio.throttle.write_iops_device 2>/dev/null && iol=yes;;
		esac
		row "disk I/O limit configured" "$iol"
	fi
	row "distro family" "${id:-unknown} (major ${ver:-?})"
	row "kernel (major.minor)" "$k"
	row "architecture class" "$(uname -m | sed -E 's/^(x86_64|amd64)$/x86-64/; s/^(aarch64|arm64)$/arm64/')"
	local up; up="$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null)"
	if [ "$IN_CONTAINER" = y ]; then
		row "host time since boot" "$(ageband "$up")"
	else
		row "time since boot" "$(ageband "$up")"
	fi
}

# ---------------------------------------------------------------- shared sample window
# One before/after snapshot (CPU, cgroup, disk, vmstat) used by several sections.

declare -A D0 D1 V0 V1 L0 L1
N0=""; N1=""
S_CPU0=""; S_CPU1=""; S_CU0=""; S_CU1=""; S_TH0=""; S_TH1=""

snap_vmstat() { # array-name
	local -n arr="$1"; local k v
	while read -r k v; do arr[$k]="$v"; done < <(awk '
		$1=="pswpin"||$1=="pswpout"||$1=="pgmajfault"||$1=="pgscan_direct" {print $1,$2}
		$1 ~ /^allocstall/ {a+=$2}
		END{print "allocstall", a+0}' /proc/vmstat 2>/dev/null)
}
snap_disk() { # array-name
	local -n arr="$1"; local l
	while read -r l; do arr[${l%% *}]="${l#* }"; done < <(awk '{print $3, $13}' /proc/diskstats 2>/dev/null)
}

# per-device "reads read_ms writes write_ms" for latency
snap_lat() { # array-name
	local -n arr="$1"
	while read -r k v; do arr[$k]="$v"; done < <(awk '{print $3, $4, $7, $8, $11}' /proc/diskstats 2>/dev/null)
}
# network counters summed over non-loopback interfaces + TCP segments:
# "rx_pk rx_err rx_drop tx_pk tx_err tx_drop tcp_out tcp_retrans"
snap_net() {
	local dev tcp
	dev="$(awk -F'[: ]+' 'NR>2 && $2!="lo" {rp+=$4; re+=$5; rd+=$6; tp+=$12; te+=$13; td+=$14} END{print rp+0, re+0, rd+0, tp+0, te+0, td+0}' /proc/net/dev 2>/dev/null)"
	tcp="$(awk '/^Tcp:/{ if (!h) {for(i=1;i<=NF;i++){if($i=="OutSegs")o=i; if($i=="RetransSegs")r=i}; h=1} else print $o, $r }' /proc/net/snmp 2>/dev/null)"
	echo "$dev $tcp"
}

sample_begin() {
	S_CPU0="$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)"
	if [ "$IN_CONTAINER" = y ] && [ "$CGV" != none ]; then
		cg_dirs self
		S_CU0="$(cg_cpu_usage_usec)"; S_TH0="$(cg_throttle)"
	fi
	snap_disk D0; snap_vmstat V0; snap_lat L0; N0="$(snap_net)"
}
sample_end() {
	S_CPU1="$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)"
	if [ "$IN_CONTAINER" = y ] && [ "$CGV" != none ]; then
		cg_dirs self
		S_CU1="$(cg_cpu_usage_usec)"; S_TH1="$(cg_throttle)"
	fi
	snap_disk D1; snap_vmstat V1; snap_lat L1; N1="$(snap_net)"
}
vdelta() { echo $(( ${V1[$1]:-0} - ${V0[$1]:-0} )); }

s_cpu_mem() {
	local sfx=""
	[ "$IN_CONTAINER" = y ] && sfx=" (host-wide)"
	hdr "CPU and memory (relative)"

	local lp l1 l5
	read -r l1 l5 _ < /proc/loadavg
	lp="$(awk -v l="$l1" -v c="$HOST_CORES" 'BEGIN{ if (c>0) printf "%d", l*100/c }')"
	row "load average / cores (1m)$sfx" "$(band "$lp")"
	lp="$(awk -v l="$l5" -v c="$HOST_CORES" 'BEGIN{ if (c>0) printf "%d", l*100/c }')"
	row "load average / cores (5m)$sfx" "$(band "$lp")"

	if [ "$IN_CONTAINER" = y ]; then
		if isnum "$S_CU0" && isnum "$S_CU1"; then
			local cb
			cb="$(awk -v d=$(( S_CU1 - S_CU0 )) -v s="$SAMPLE_SECS" -v e="$EFF_CPU_X100" 'BEGIN{ if (e>0) printf "%d", d*100/(s*1000000*e/100) }')"
			chk_band "container CPU used / effective limit" "$(band "$cb")"
		else
			row "container CPU used / effective limit" "n/a"
		fi
		if [ -n "$S_TH0" ] && [ -n "$S_TH1" ]; then
			local p0 t0 p1 t1 tb
			read -r p0 t0 <<< "$S_TH0"; read -r p1 t1 <<< "$S_TH1"
			if isnum "$p0" && isnum "$p1" && [ $(( p1 - p0 )) -gt 0 ]; then
				tb="$(band "$(pct $(( t1 - t0 )) $(( p1 - p0 )))")"
				case "$tb" in "<10%") chk "CPU throttled periods" OK "$tb";;
					*) chk "CPU throttled periods" WARN "$tb (limit too tight)";; esac
			else
				row "CPU throttled periods" "none / no quota"
			fi
		fi
	fi

	set -- $S_CPU0 $S_CPU1
	local tot=0 i
	for i in 1 2 3 4 5 6 7 8; do
		tot=$(( tot + ${@:$((i+8)):1} - ${@:$i:1} ))
	done
	if [ "$tot" -gt 0 ]; then
		local us sy io st
		us=$(( ( (${10}-$2) + (${9}-$1) ) * 100 / tot ))
		sy=$(( ( (${11}-$3) + (${14}-$6) + (${15}-$7) ) * 100 / tot ))
		io=$(( (${13}-$5) * 100 / tot ))
		st=$(( (${16}-$8) * 100 / tot ))
		row "CPU user$sfx" "$(band $us)"
		row "CPU system/irq$sfx" "$(band $sy)"
		row "CPU iowait$sfx" "$(band $io)"
		if [ "$st" -ge 5 ]; then
			chk "CPU steal$sfx" WARN "$(band $st) (hypervisor contention)"
		else
			chk "CPU steal$sfx" OK "$(band $st)"
		fi
	fi

	local mt ma st sf dirty cached
	mt="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
	ma="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
	st="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
	sf="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"
	dirty="$(awk '/^Dirty:/{print $2}' /proc/meminfo)"
	cached="$(awk '/^Cached:/{print $2}' /proc/meminfo)"

	if [ "$IN_CONTAINER" = y ] && [ "$CGV" != none ]; then
		cg_dirs self
		local ws oomk
		ws="$(cg_mem_workingset)"
		if isnum "$ws"; then
			if [ "$MEM_LIMITED" = y ]; then
				chk_band "container working set / memory limit" "$(band "$(pct $(( ws / 1024 )) "$EFF_MEM_KB")")"
			else
				row "container working set / host RAM" "$(band "$(pct $(( ws / 1024 )) "$EFF_MEM_KB")") (no limit set)"
			fi
		else
			row "container working set / memory limit" "n/a"
		fi
		oomk="$(cg_oom_kills)"
		if isnum "$oomk"; then
			if [ "$oomk" -eq 0 ]; then chk "container OOM kills" OK none
			else chk "container OOM kills" WARN "$(countband "$oomk")"; fi
		fi
	fi
	row "host memory available$sfx" "$(band "$(pct "$ma" "$mt")")"
	row "host page cache / total$sfx" "$(band "$(pct "$cached" "$mt")")"
	row "host dirty pages / total$sfx" "$(band "$(pct "$dirty" "$mt")")"
	if [ "${st:-0}" -eq 0 ]; then
		row "swap$sfx" "not configured"
	else
		local su=$(( st - sf ))
		if [ "$su" -gt 0 ]; then chk "swap in use / total$sfx" WARN "$(band "$(pct "$su" "$st")")"
		else chk "swap in use / total$sfx" OK "<10%"; fi
	fi

	local nodes
	nodes="$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)"
	if [ "$nodes" -gt 1 ]; then NUMA_MULTI=y; row "NUMA$sfx" "multi-node"; else NUMA_MULTI=n; row "NUMA$sfx" "single node / none"; fi
}

s_cpu_features() {
	hdr "CPU features"
	if [ "$(uname -m)" = x86_64 ]; then
		if grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -qw avx; then
			chk "AVX supported (needed by MongoDB 5.0+)" OK yes
		else
			chk "AVX supported (needed by MongoDB 5.0+)" WARN "no (or masked by hypervisor)"
		fi
	else
		row "AVX supported" "n/a (non-x86)"
	fi
	local g; g="$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
	case "$g" in
		performance) chk "CPU frequency governor" OK "performance";;
		powersave)   chk "CPU frequency governor" WARN "powersave";;
		"")          row "CPU frequency governor" "not exposed (VM/container/fixed freq)";;
		*)           chk "CPU frequency governor" INFO "$g";;
	esac
	case "$(rd /sys/devices/system/cpu/smt/active)" in
		1) row "SMT / hyperthreading" "enabled";;
		0) row "SMT / hyperthreading" "disabled";;
		*) row "SMT / hyperthreading" "n/a";;
	esac
}

# PSI: share of time tasks were stalled (60s average)
psi_one() { # label file kind(some|full) warn-threshold
	local f v
	f="$(awk -v k="$3" '$1==k{print $3}' "$2" 2>/dev/null)"
	[ -z "$f" ] && return
	v="${f#avg60=}"; v="${v%%.*}"
	isnum "$v" || return
	if [ "$v" -ge "$4" ]; then chk "$1" WARN "$(band "$v") - elevated"; else chk "$1" OK "$(band "$v")"; fi
}
psi_group() { # prefix cpu-file mem-file io-file
	psi_one "$1 CPU some"    "$2" some 25
	psi_one "$1 memory some" "$3" some 10
	psi_one "$1 memory full" "$3" full 5
	psi_one "$1 I/O some"    "$4" some 10
	psi_one "$1 I/O full"    "$4" full 5
}
s_pressure() {
	hdr "Pressure stalls (PSI, share of time stalled, 60s window)"
	local any=n
	if [ "$IN_CONTAINER" = y ] && [ "$CGV" = v2 ]; then
		cg_dirs self
		if [ -r "$CPUDIR/cpu.pressure" ]; then
			psi_group "container" "$CPUDIR/cpu.pressure" "$MEMDIR/memory.pressure" "$MEMDIR/io.pressure"; any=y
		fi
	fi
	if [ -r /proc/pressure/cpu ]; then
		local pre="host"; [ "$IN_CONTAINER" = y ] && pre="host-wide"
		psi_group "$pre" /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; any=y
	fi
	[ "$any" = n ] && row "PSI" "not available (kernel < 4.20 or disabled)"
}

s_memory_activity() {
	local sfx=""; [ "$IN_CONTAINER" = y ] && sfx=" (host-wide)"
	hdr "Memory activity during sample$sfx"
	if [ -z "${V1[allocstall]}" ]; then row "vmstat" "n/a"; return; fi
	local s=$SAMPLE_SECS sw mf as ds
	sw=$(( $(vdelta pswpin) + $(vdelta pswpout) ))
	if   [ "$sw" -eq 0 ];            then chk "swap in/out activity" OK none
	elif [ $(( sw / s )) -le 25 ];   then chk "swap in/out activity" INFO light
	else chk "swap in/out activity" WARN heavy; fi
	mf=$(( $(vdelta pgmajfault) / s ))
	if   [ "$mf" -le 10 ];  then chk "major page faults" OK low
	elif [ "$mf" -le 200 ]; then chk "major page faults" INFO moderate
	else chk "major page faults" WARN high; fi
	as=$(vdelta allocstall); ds=$(vdelta pgscan_direct)
	if [ "$as" -gt 0 ] || [ "$ds" -gt 0 ]; then chk "direct reclaim (allocation stalls)" WARN occurring
	else chk "direct reclaim (allocation stalls)" OK none; fi

	# share of free memory available in large (>= order 9) blocks
	if [ -r /proc/buddyinfo ]; then
		local fr
		fr="$(awk '{ t=0; h=0; for (i=5;i<=NF;i++) { o=i-5; t+=$i*2^o; if (o>=9) h+=$i*2^o }
		            T+=t; H+=h } END{ if (T>0) printf "%d", H*100/T }' /proc/buddyinfo)"
		if isnum "$fr" && [ "$fr" -lt 10 ]; then
			chk "free memory in large blocks" INFO "$(band "$fr") (fragmented, hurts THP/hugepages)"
		elif isnum "$fr"; then
			row "free memory in large blocks" "$(band "$fr")"
		fi
	fi
}

s_kernel() {
	local sfx=""
	[ "$IN_CONTAINER" = y ] && sfx=" - host kernel"
	hdr "Kernel settings vs. MongoDB production recommendations$sfx"
	local v f

	v="$(rd /proc/sys/vm/swappiness)"
	if ! isnum "$v"; then row "vm.swappiness" "n/a"
	elif [ "$v" -le 1 ]; then chk "vm.swappiness" OK "at/below recommended"
	else chk "vm.swappiness" WARN "above recommended"; fi

	v="$(rd /proc/sys/vm/zone_reclaim_mode)"
	if ! isnum "$v"; then row "vm.zone_reclaim_mode" "n/a"
	elif [ "$v" -eq 0 ]; then chk "vm.zone_reclaim_mode" OK "disabled"
	else chk "vm.zone_reclaim_mode" WARN "enabled"; fi

	v="$(rd /proc/sys/vm/overcommit_memory)"
	case "$v" in
		0|1) chk "vm.overcommit_memory" OK "heuristic/always (not strict)";;
		2)   chk "vm.overcommit_memory" WARN "strict mode";;
		*)   row "vm.overcommit_memory" "n/a";;
	esac

	v="$(rd /proc/sys/vm/max_map_count)"
	if ! isnum "$v"; then row "vm.max_map_count" "n/a"
	elif [ "$v" -ge 102400 ]; then chk "vm.max_map_count" OK "meets recommendation"
	else chk "vm.max_map_count" WARN "below recommendation"; fi

	v="$(rd /proc/sys/net/ipv4/tcp_keepalive_time)"
	if ! isnum "$v"; then row "tcp_keepalive_time" "n/a"
	elif [ "$v" -le 300 ]; then chk "tcp_keepalive_time" OK "at/below recommended"
	else chk "tcp_keepalive_time" WARN "above recommended"; fi

	for f in enabled defrag; do
		v="$(rd /sys/kernel/mm/transparent_hugepage/$f | sed -E 's/.*\[([^]]+)\].*/\1/')"
		[ -z "$v" ] && v="$(rd /sys/kernel/mm/redhat_transparent_hugepage/$f | sed -E 's/.*\[([^]]+)\].*/\1/')"
		if [ -z "$v" ]; then row "THP $f" "n/a"
		elif [ "$f" = enabled ]; then
			if [ "$v" = never ]; then chk "THP enabled" OK "never"
			else chk "THP enabled" WARN "mode: $v"; fi
		else
			row "THP defrag" "$v"
		fi
	done

	v="$(rd /sys/devices/system/clocksource/clocksource0/current_clocksource)"
	case "$v" in
		tsc|kvm-clock|arch_sys_counter) chk "clocksource" OK "fast ($v)";;
		"") row "clocksource" "n/a";;
		*)  chk "clocksource" INFO "$v";;
	esac

	if have getenforce; then row "SELinux" "$(getenforce 2>/dev/null)"
	elif [ -r /sys/fs/selinux/enforce ]; then
		[ "$(rd /sys/fs/selinux/enforce)" = 1 ] && row "SELinux" "Enforcing" || row "SELinux" "Permissive"
	else row "SELinux" "not present / not visible"; fi
}

s_time() {
	hdr "Time synchronization"
	if [ "$IN_CONTAINER" = y ]; then
		row "clock" "inherited from host (not checkable from container)"
		return
	fi
	local daemon="none" sync="unknown"
	if   have_proc chronyd;            then daemon=chrony
	elif have_proc ntpd;               then daemon=ntp
	elif have_proc systemd-timesyncd;  then daemon=timesyncd
	fi
	row "sync daemon" "$daemon"
	if have timedatectl; then
		case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" in
			yes) sync=yes;; no) sync=no;;
		esac
	fi
	if [ "$sync" = unknown ] && have chronyc; then
		chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && sync=yes
	fi
	case "$sync" in
		yes) chk "clock synchronized" OK yes;;
		no)  chk "clock synchronized" WARN no;;
		*)   row "clock synchronized" unknown;;
	esac
}

# one block device: type, scheduler, read-ahead, busy% (labels only, never names)
disk_report() { # label sysname
	local label="$1" n="$2" d="/sys/block/$2" rot slaves kind sched ra rac busy
	rot="$(rd "$d/queue/rotational")"
	slaves="$(ls "$d/slaves" 2>/dev/null | wc -l)"
	if [ "$slaves" -gt 0 ]; then kind="stacked (LVM/RAID/dm)"
	elif [ "$rot" = 0 ]; then kind="non-rotational"
	elif [ "$rot" = 1 ]; then kind="rotational flag set"
	else kind="unknown"; fi
	sched="$(rd "$d/queue/scheduler" | sed -E 's/.*\[([^]]+)\].*/\1/')"
	ra="$(rd "$d/queue/read_ahead_kb")"
	if ! isnum "$ra"; then rac="n/a"
	elif [ "$ra" -le 32 ]; then rac="within recommended range"
	elif [ "$ra" -le 256 ]; then rac="moderately above recommended"
	else rac="far above recommended"; fi
	busy=""
	if isnum "${D0[$n]}" && isnum "${D1[$n]}"; then
		busy=$(( (D1[$n] - D0[$n]) * 100 / (SAMPLE_SECS * 1000) ))
	fi
	row "$label type" "$kind"
	row "$label scheduler" "${sched:-n/a}"
	if [ "$rac" = "far above recommended" ]; then chk "$label read-ahead" WARN "$rac"
	else row "$label read-ahead" "$rac"; fi
	chk_band "$label busy (sample)" "$(band "$busy")"
	disk_latency "$label" "$n"
}

# average read/write latency over the sample, qualitative (no absolute values)
disk_latency() { # label sysname
	local label="$1" n="$2" a b rd wd rl wl
	a=(${L0[$n]}); b=(${L1[$n]})
	[ "${#a[@]}" -eq 4 ] && [ "${#b[@]}" -eq 4 ] || { row "$label latency" "n/a"; return; }
	rd=$(( b[0] - a[0] )); wd=$(( b[2] - a[2] ))
	_lat() { # ops ms kind -> label
		if [ "$1" -le 0 ]; then echo "no I/O in sample"; return; fi
		local avg=$(( $2 / $1 ))
		if   [ "$avg" -lt 2 ];  then echo "OK:fast"
		elif [ "$avg" -lt 10 ]; then echo "OK:normal"
		elif [ "$avg" -lt 50 ]; then echo "WARN:slow"
		else echo "WARN:very slow"; fi
	}
	for k in read write; do
		local r
		if [ "$k" = read ]; then r="$(_lat "$rd" $(( b[1] - a[1] )))"; else r="$(_lat "$wd" $(( b[3] - a[3] )))"; fi
		case "$r" in
			OK:*)   chk "$label $k latency" OK "${r#OK:}";;
			WARN:*) chk "$label $k latency" WARN "${r#WARN:} (compared with typical SSD/NVMe behaviour)";;
			*)      row "$label $k latency" "$r";;
		esac
	done
}

# the physical/stacked disk behind a major:minor (used for the data volume)
data_disk() { # label major:minor
	local blk n s sn p k=0
	[ -e "/sys/dev/block/$2" ] || { row "$1" "n/a (virtual/network filesystem)"; return; }
	blk="$(readlink -f "/sys/dev/block/$2")"
	[ -f "$blk/partition" ] && blk="${blk%/*}"
	n="${blk##*/}"
	[ -d "/sys/block/$n" ] || { row "$1" "n/a"; return; }
	disk_report "$1" "$n"
	for s in /sys/block/$n/slaves/*; do
		[ -e "$s" ] || continue
		k=$((k+1)); [ "$k" -gt 8 ] && break
		sn="${s##*/}"
		p="$(readlink -f "/sys/class/block/$sn" 2>/dev/null)"
		[ -f "$p/partition" ] && sn="$(basename "$(dirname "$p")")"
		[ -d "/sys/block/$sn" ] && disk_report "$1 member$k" "$sn"
	done
}

s_storage() {
	local sfx=""
	[ "$IN_CONTAINER" = y ] && sfx=" - host-visible devices; may not map to the data volume"
	hdr "Block devices (anonymized)$sfx"
	local i=0 d n
	for d in /sys/block/*; do
		[ -d "$d" ] || continue
		n="${d##*/}"
		case "$n" in loop*|ram*|sr*|fd*|zram*|nbd*) continue;; esac
		i=$((i+1))
		disk_report "disk$i" "$n"
	done
	[ "$i" -eq 0 ] && row "disks" "none visible"

	hdr "Filesystems visible to this environment (anonymized)"
	local fsn=0 dev mp fst use
	declare -A seen
	while read -r dev mp fst; do
		case "$fst" in proc|sysfs|tmpfs|devtmpfs|devpts|cgroup|cgroup2|mqueue|securityfs|debugfs|tracefs|pstore|bpf|configfs|fusectl|hugetlbfs|autofs|binfmt_misc|efivarfs|nsfs|selinuxfs|rpc_pipefs|ramfs|squashfs) continue;; esac
		[ -d "$mp" ] || continue
		[ -n "${seen[$dev]}" ] && continue
		seen[$dev]=1
		use="$(df -P "$mp" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
		fsn=$((fsn+1))
		row "fs$fsn type" "$fst"
		if [ "$fst" = overlay ]; then row "fs$fsn role" "container writable layer"; fi
		row "fs$fsn space used" "$(band "$use")"
	done < <(awk '{ for (i=7;i<=NF;i++) if ($i=="-") break; print $3, $5, $(i+1) }' /proc/self/mountinfo 2>/dev/null)
	[ "$fsn" -eq 0 ] && row "filesystems" "none visible"
}

s_capacity() {
	hdr "Capacity headroom (used / limit)"
	local a u m r
	read -r a u m < /proc/sys/fs/file-nr 2>/dev/null
	if isnum "$a" && isnum "$m"; then chk_band "open files (system-wide)" "$(band "$(pct "$a" "$m")")"; fi

	local f4 tt tm pm lim
	f4="$(awk '{print $4}' /proc/loadavg)"; tt="${f4#*/}"
	tm="$(rd /proc/sys/kernel/threads-max)"; pm="$(rd /proc/sys/kernel/pid_max)"
	lim="$tm"; isnum "$pm" && { ! isnum "$lim" || [ "$pm" -lt "$lim" ]; } && lim="$pm"
	if isnum "$tt" && isnum "$lim"; then chk_band "threads / min(threads-max,pid_max)" "$(band "$(pct "$tt" "$lim")")"; fi

	if [ "$IN_CONTAINER" = y ] && [ "$CGV" != none ]; then
		local pc pmx
		if [ "$CGV" = v2 ]; then cg_dirs self; pc="$(rd "$MEMDIR/pids.current")"; pmx="$(rd "$MEMDIR/pids.max")"
		else pc="$(rd /sys/fs/cgroup/pids/pids.current)"; pmx="$(rd /sys/fs/cgroup/pids/pids.max)"; fi
		if isnum "$pc" && isnum "$pmx" && [ "$pmx" -gt 0 ]; then
			chk_band "container PIDs / pids.max" "$(band "$(pct "$pc" "$pmx")")"
		elif isnum "$pc"; then
			row "container PIDs limit" "none"
		fi
	fi

	local lo hi nconn
	read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null
	if isnum "$lo" && isnum "$hi" && [ -r /proc/net/tcp ]; then
		nconn="$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk 'FNR>1 && $4!="0A"{n++} END{print n+0}')"
		chk_band "TCP sockets / ephemeral port range" "$(band "$(pct "$nconn" $(( hi - lo + 1 )))")"
	fi

	local cc cm
	cc="$(rd /proc/sys/net/netfilter/nf_conntrack_count)"; cm="$(rd /proc/sys/net/netfilter/nf_conntrack_max)"
	if isnum "$cc" && isnum "$cm"; then chk_band "conntrack table used" "$(band "$(pct "$cc" "$cm")")"; fi

	r="$(rd /proc/sys/net/core/somaxconn)"
	if isnum "$r"; then
		if [ "$r" -ge 1024 ]; then chk "net.core.somaxconn" OK "meets recommendation"
		else chk "net.core.somaxconn" WARN "low (connection backlog may overflow)"; fi
	fi
	local dr db
	dr="$(rd /proc/sys/vm/dirty_ratio)"; db="$(rd /proc/sys/vm/dirty_background_ratio)"
	if isnum "$db" && [ "$(rd /proc/sys/vm/dirty_background_bytes)" = 0 ]; then
		if [ "$db" -le 10 ]; then chk "vm.dirty_background_ratio" OK "at/below recommended"
		else chk "vm.dirty_background_ratio" WARN "high (write-back bursts)"; fi
	fi
	if isnum "$dr" && [ "$(rd /proc/sys/vm/dirty_bytes)" = 0 ]; then
		if [ "$dr" -le 30 ]; then chk "vm.dirty_ratio" OK "at/below recommended"
		else chk "vm.dirty_ratio" WARN "high (long write stalls)"; fi
	fi
}

# ---------------------------------------------------------------- mongo

have_proc() {   # is a process with this exact comm visible?
	local d
	for d in /proc/[0-9]*; do
		[ "$(cat "$d/comm" 2>/dev/null)" = "$1" ] && return 0
	done
	return 1
}

find_mongo_pids() {
	local d c a
	for d in /proc/[0-9]*; do
		c="$(cat "$d/comm" 2>/dev/null)"
		case "$c" in mongod|mongos) echo "${d#/proc/}"; continue;; esac
		# comm may be renamed/truncated: accept an exact argv[0] basename only
		a="$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)"
		case "${a##*/}" in mongod|mongos) echo "${d#/proc/}";; esac
	done
}

mongo_cmd_arg() {
	local cmd="$1" arg="$2" v
	v="$(printf '%s\n' "$cmd" | sed -nE "s/.*[[:space:]]${arg}[[:space:]]+([^[:space:]]+).*/\1/p; s/.*[[:space:]]${arg}=(.+)/\1/p; s/.*${arg}=([^[:space:]]+).*/\1/p" | head -1)"
	printf '%s' "${v:-}"
}

cfg_has() { printf '%s' "$CFGTXT" | grep -Eiq "$1"; }

yn_chk() { # label, regex, good-if(y|n)
	local r=n
	cfg_has "$2" && r=y
	if [ "$r" = "$3" ]; then chk "$1" OK "$([ $r = y ] && echo yes || echo no)"
	else chk "$1" WARN "$([ $r = y ] && echo yes || echo no)"; fi
}

# path as seen by the target process (works across container boundaries)
ppath() { # pid path
	if [ -d "/proc/$1/root/" ] && [ -e "/proc/$1/root$2" ]; then echo "/proc/$1/root$2"; else echo "$2"; fi
}

# classify listening TCP sockets of a pid: loopback / all-interfaces / specific-address
listen_scope() {
	local pid="$1" inodes
	inodes="$(ls -l /proc/$pid/fd 2>/dev/null | sed -nE 's/.*socket:\[([0-9]+)\].*/\1/p' | paste -sd' ' -)"
	[ -z "$inodes" ] && return
	cat /proc/$pid/net/tcp /proc/$pid/net/tcp6 2>/dev/null | awk -v inodes=" $inodes " '
		$4=="0A" && index(inodes, " " $10 " ") {
			split($2, a, ":"); h=a[1]
			if (h=="00000000" || h=="00000000000000000000000000000000") print "all-interfaces"
			else if (h=="0100007F" || h=="00000000000000000000000001000000" || h ~ /7F$/ && length(h)==8) print "loopback"
			else print "specific-address"
		}' | sort -u | paste -sd, -
}

s_mongo() {
	hdr "MongoDB processes"
	local pids n=0 pid
	pids="$(find_mongo_pids)"
	if [ -z "$pids" ]; then
		row "mongod/mongos visible" "no"
		if [ "$IN_CONTAINER" = y ]; then
			row "hint" "mongod may run in another container; run inside it or share the process namespace"
		fi
		return
	fi
	local hz up
	hz="$(getconf CLK_TCK 2>/dev/null)"; isnum "$hz" || hz=100
	up="$(awk '{print $1}' /proc/uptime)"

	for pid in $pids; do
		n=$((n+1))
		local role cmd cfgfile cfgp
		role="$(cat /proc/$pid/comm 2>/dev/null)"
		cmd="$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)"
		cfgfile="$(mongo_cmd_arg "$cmd" '--config')"
		[ -z "$cfgfile" ] && cfgfile="$(mongo_cmd_arg "$cmd" '-f')"
		CFGTXT="$cmd"
		if [ -n "$cfgfile" ]; then
			cfgp="$(ppath "$pid" "$cfgfile")"
			[ -r "$cfgp" ] && CFGTXT="$CFGTXT
$(grep -vE '^[[:space:]]*#' "$cfgp" 2>/dev/null)"
		fi

		echo
		row "[mongo$n] role" "$role"
		row "[mongo$n] config file used" "$([ -n "$cfgfile" ] && echo yes || echo no)"

		local ver
		ver="$("/proc/$pid/exe" --version 2>/dev/null | sed -nE 's/.*(db|mongos) version v([0-9]+\.[0-9]+).*/\2/p' | head -1)"
		row "[mongo$n] version (major.minor)" "${ver:-n/a}"

		# runtime, relative; computed from /proc (no ps dependency)
		local stat ut st0 age cpusec rss thr
		stat="$(sed -E 's/^.*\) //' /proc/$pid/stat 2>/dev/null)"
		read -r ut st0 age <<< "$(echo "$stat" | awk -v hz="$hz" '{printf "%d %d %d", $12+$13, $20, 0}')"
		if isnum "$ut" && isnum "$st0"; then
			age=$(awk -v up="$up" -v s="$st0" -v hz="$hz" 'BEGIN{ printf "%d", up - s/hz }')
			row "[mongo$n] process age" "$(ageband "$age")"
			local cb
			cb="$(awk -v u="$ut" -v hz="$hz" -v a="$age" -v e="$EFF_CPU_X100" 'BEGIN{ if (a>0 && e>0) printf "%d", (u/hz)/a*100/(e/100) }')"
			row "[mongo$n] CPU lifetime avg / eff. CPUs" "$(band "$cb")"
		fi
		rss="$(awk '/^VmRSS:/{print $2}' /proc/$pid/status 2>/dev/null)"
		if isnum "$rss"; then
			chk_band "[mongo$n] RSS / effective memory" "$(band "$(pct "$rss" "$EFF_MEM_KB")")"
		fi

		# fds and limits (nofile/nproc)
		local fds lim
		lim="$(awk '/^Max open files/{print $4}' /proc/$pid/limits 2>/dev/null)"
		fds="$(ls /proc/$pid/fd 2>/dev/null | wc -l)"
		if [ -r /proc/$pid/fd ] && isnum "$lim" && [ "$fds" -gt 0 ]; then
			chk_band "[mongo$n] fd used / limit" "$(band "$(pct "$fds" "$lim")")"
		else
			row "[mongo$n] fd used / limit" "n/a (permission)"
		fi
		if [ "$lim" = unlimited ] || { isnum "$lim" && [ "$lim" -ge 64000 ]; }; then
			chk "[mongo$n] nofile limit" OK "meets recommendation"
		elif isnum "$lim"; then
			chk "[mongo$n] nofile limit" WARN "below recommendation"
		fi
		lim="$(awk '/^Max processes/{print $3}' /proc/$pid/limits 2>/dev/null)"
		if [ "$lim" = unlimited ] || { isnum "$lim" && [ "$lim" -ge 64000 ]; }; then
			chk "[mongo$n] nproc limit" OK "meets recommendation"
		elif isnum "$lim"; then
			chk "[mongo$n] nproc limit" WARN "below recommendation"
		fi

		# per-process cgroup memory cap vs host RAM
		if [ "$CGV" != none ]; then
			cg_dirs "$pid"
			local cap hostmem
			cap="$(cg_mem_limit)"
			hostmem="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
			if isnum "$cap" && [ $(( cap / 1024 )) -lt "$hostmem" ]; then
				row "[mongo$n] cgroup memory cap" "$(membucket "$((cap / 1024))")"
			else
				row "[mongo$n] cgroup memory cap" "none"
			fi
		fi

		# NUMA
		if [ "$NUMA_MULTI" = y ]; then
			if grep -m1 -q interleave /proc/$pid/numa_maps 2>/dev/null; then
				chk "[mongo$n] NUMA interleave" OK yes
			else
				chk "[mongo$n] NUMA interleave" WARN "no (multi-node host)"
			fi
		fi

		# security / topology flags: booleans only, never values
		yn_chk "[mongo$n] authorization enabled" '(^|[ ])--auth( |$)|authorization:[[:space:]]*"?enabled|^[[:space:]]*auth[[:space:]]*=[[:space:]]*true' y
		yn_chk "[mongo$n] TLS/SSL enabled" '(tls|ssl)Mode[ :=]+"?(require|prefer|allow)|^[[:space:]]*mode:[[:space:]]*"?(require|prefer|allow)(TLS|SSL)' y
		row "[mongo$n] replica set member" "$(cfg_has 'replSet' && echo yes || echo no)"
		row "[mongo$n] sharded cluster role" "$(cfg_has 'shardsvr|configsvr|clusterRole' && echo yes || echo no)"
		row "[mongo$n] storage engine" "$(cfg_has 'inMemory' && echo in-memory || echo default)"

		local scopes
		scopes="$(listen_scope "$pid")"
		row "[mongo$n] listen scope" "${scopes:-n/a}"

		# data volume (path never printed); fs type/options from the process's own mountinfo
		local dbp dbr
		dbp="$(mongo_cmd_arg "$CFGTXT" '--dbpath')"
		[ -z "$dbp" ] && dbp="$(printf '%s\n' "$CFGTXT" | sed -nE 's/.*--dbpath[ =]"?([^" ]+).*/\1/p;s/^[[:space:]]*dbPath:[[:space:]]*"?([^" ]+).*/\1/p;s/^[[:space:]]*dbpath[[:space:]]*=[[:space:]]*([^ ]+).*/\1/p' | head -1)"
		[ -z "$dbp" ] && dbp="$(printf '%s\n' "$CFGTXT" | sed -nE 's/.*--dbpath=([[:space:]]*[^[:space:]]+).*/\1/p' | head -1)"
		[ -z "$dbp" ] && dbp="/var/lib/mongodb"
		dbr="$(ppath "$pid" "$dbp")"
		if [ -d "$dbr" ]; then
			local mi fst mo dv use iu
			mi="$(awk -v p="$dbp" '
				{ mp=$5; for (i=7;i<=NF;i++) if ($i=="-") break; f=$(i+1)
				  if (p==mp || index(p, mp=="/" ? "/" : mp "/")==1) if (length(mp)>=best) { best=length(mp); opts=$6; fs=f; dev=$3 } }
				END{ print fs, opts, dev }' /proc/$pid/mountinfo 2>/dev/null)"
			read -r fst mo dv <<< "$mi"
			use="$(df -P "$dbr" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
			iu="$(df -Pi "$dbr" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
			row "[mongo$n] data fs type" "${fst:-n/a}"
			case "$fst" in
				xfs)     chk "[mongo$n] data fs recommended" OK "xfs";;
				ext4)    chk "[mongo$n] data fs recommended" INFO "ext4 (xfs preferred for WiredTiger)";;
				overlay) chk "[mongo$n] data on dedicated volume" WARN "no - container writable layer";;
				nfs*|cifs|smb*|fuse*) chk "[mongo$n] data fs recommended" WARN "network/FUSE filesystem";;
				"")      ;;
				*)       chk "[mongo$n] data fs recommended" INFO "other fs";;
			esac
			chk_band "[mongo$n] data fs space used" "$(band "$use")"
			row "[mongo$n] data fs inodes used" "$(band "$iu")"
			case ",$mo," in *,noatime,*) chk "[mongo$n] data fs noatime" OK yes;; *) chk "[mongo$n] data fs noatime" INFO no;; esac
			[ -n "$dv" ] && data_disk "[mongo$n] data disk" "$dv"
		else
			row "[mongo$n] data fs" "n/a (path not resolved)"
		fi
	done
	echo
	row "mongod/mongos process count class" "$([ "$n" -gt 1 ] && echo multiple || echo single)"
}

s_events() {
	hdr "Kernel log events (counts reported as none/few/many)"
	local log
	log="$(dmesg 2>/dev/null)"
	if [ -z "$log" ]; then
		row "dmesg" "n/a (not permitted / not available$([ "$IN_CONTAINER" = y ] && echo ' in container'))"
		return
	fi
	local oom io mce hung seg mo p label cnt
	oom=$(printf '%s\n' "$log" | grep -Eic 'out of memory|oom-kill')
	mo=$(printf '%s\n' "$log" | grep -Eic 'killed process.*mongo')
	io=$(printf '%s\n' "$log" | grep -Eic 'i/o error|blk_update_request')
	mce=$(printf '%s\n' "$log" | grep -Eic 'machine check|mce:')
	hung=$(printf '%s\n' "$log" | grep -Eic 'blocked for more than')
	seg=$(printf '%s\n' "$log" | grep -Eic 'segfault')
	for p in "OOM events:$oom" "OOM kill hit MongoDB:$mo" "I/O errors:$io" "machine check:$mce" "hung tasks:$hung" "segfaults:$seg"; do
		label="${p%%:*}"; cnt="${p##*:}"
		if [ "$cnt" -eq 0 ]; then chk "$label" OK "$(countband "$cnt")"
		else chk "$label" WARN "$(countband "$cnt")"; fi
	done
}

s_network() {
	hdr "Network posture (no addresses)"
	if [ "$IN_CONTAINER" = y ]; then
		row "packet filtering" "not checkable from container (CNI / host / network policy)"
	else
		local fw="unknown" rules
		if have_proc firewalld; then fw="firewalld active"
		elif have iptables; then
			rules="$(iptables -S 2>/dev/null | grep -vc '^-P')"
			if isnum "$rules"; then [ "$rules" -gt 0 ] && fw="iptables rules present" || fw="no iptables rules"; fi
		fi
		row "packet filtering" "$fw"
	fi

	local a=($N0) b=($N1) i ok=y
	[ "${#a[@]}" -eq 8 ] && [ "${#b[@]}" -eq 8 ] || ok=n
	for i in "${a[@]}" "${b[@]}"; do isnum "$i" || ok=n; done
	if [ "$ok" = y ]; then
		local pk=$(( b[0]+b[3] )) er=$(( b[1]+b[2]+b[4]+b[5] ))
		local dpk=$(( b[0]+b[3]-a[0]-a[3] )) der=$(( b[1]+b[2]+b[4]+b[5]-a[1]-a[2]-a[4]-a[5] ))
		# interface errors/drops: lifetime ratio and sample activity
		if [ "$pk" -le 0 ]; then row "interface errors+drops (since boot)" "no traffic"
		else
			local r; r="$(awk -v e="$er" -v p="$pk" 'BEGIN{x=e*100/p; if(e==0)print "none"; else if(x<0.1)print "<0.1% of packets"; else if(x<1)print "0.1-1% of packets"; else print ">=1% of packets"}')"
			case "$r" in none|"<0.1% of packets") chk "interface errors+drops (since boot)" OK "$r";;
				*) chk "interface errors+drops (since boot)" WARN "$r";; esac
		fi
		if [ "$dpk" -le 0 ]; then row "interface errors+drops (sample)" "no traffic"
		elif [ "$der" -le 0 ]; then chk "interface errors+drops (sample)" OK none
		else chk "interface errors+drops (sample)" WARN "$(countband "$der")"; fi

		# TCP retransmissions
		local tout=${b[6]} tre=${b[7]} dout=$(( b[6]-a[6] )) dre=$(( b[7]-a[7] ))
		if [ "$tout" -le 0 ]; then row "TCP retransmits (since boot)" "no traffic"
		else
			local r; r="$(awk -v e="$tre" -v p="$tout" 'BEGIN{x=e*100/p; if(e==0)print "none"; else if(x<0.1)print "<0.1% of segments"; else if(x<1)print "0.1-1% of segments"; else if(x<5)print "1-5% of segments"; else print ">=5% of segments"}')"
			case "$r" in none|"<0.1% of segments"|"0.1-1% of segments") chk "TCP retransmits (since boot)" OK "$r";;
				*) chk "TCP retransmits (since boot)" WARN "$r (lossy or congested network)";; esac
		fi
		if [ "$dout" -le 0 ]; then row "TCP retransmits (sample)" "no traffic"
		else
			local r; r="$(awk -v e="$dre" -v p="$dout" 'BEGIN{x=e*100/p; if(e==0)print "none"; else if(x<1)print "<1% of segments"; else if(x<5)print "1-5% of segments"; else print ">=5% of segments"}')"
			case "$r" in none|"<1% of segments") chk "TCP retransmits (sample)" OK "$r";;
				*) chk "TCP retransmits (sample)" WARN "$r";; esac
		fi
	else
		row "interface errors+drops" "n/a"
		row "TCP retransmits" "n/a"
	fi

	# TCP socket states in this network namespace
	if [ -r /proc/net/tcp ]; then
		local tw cw
		read -r tw cw < <(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '$4=="06"{t++} $4=="08"{c++} END{print t+0, c+0}')
		if isnum "$tw" && isnum "$cw"; then
			if [ "$tw" -gt 1000 ]; then chk "TCP sockets in TIME_WAIT" WARN "many (churn of short connections)"
			else chk "TCP sockets in TIME_WAIT" OK "$(countband "$tw")"; fi
			if [ "$cw" -gt 0 ]; then chk "TCP sockets in CLOSE_WAIT" WARN "$(countband "$cw") (peer closed, app has not)"
			else chk "TCP sockets in CLOSE_WAIT" OK none; fi
		fi
	fi
}

# ---------------------------------------------------------------- main

usage() {
	cat <<USAGE
Usage: bash mdiag-safe.sh [--sample SECONDS] [--help]
  --sample N   length of the measurement window (default 5, range 1-300)
  Output goes to stdout. Exit code 3 means the anonymity audit had to mask data.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--sample) shift; SAMPLE_SECS="$1";;
		--help|-h) usage; exit 0;;
		*) echo "mdiag-safe.sh: unknown parameter" >&2; usage >&2; exit 1;;
	esac
	shift
done
if ! isnum "$SAMPLE_SECS" || [ "$SAMPLE_SECS" -lt 1 ] || [ "$SAMPLE_SECS" -gt 300 ]; then
	echo "mdiag-safe.sh: --sample must be 1-300" >&2; exit 1
fi

report_body() {
	detect_env
	sample_begin
	sleep "$SAMPLE_SECS"
	sample_end
	s_platform
	s_cpu_features
	s_cpu_mem
	s_pressure
	s_memory_activity
	s_kernel
	s_capacity
	s_time
	s_storage
	s_network
	s_mongo
	s_events
	echo
	echo "-- end of report --"
}

# Final scrub: remove anything that still looks like identifying data.
scrub() {
	local h hs u
	h="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"; hs="${h%%.*}"; u="$(id -un 2>/dev/null)"
	local sedargs=(
		-E
		-e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip-removed>/g'
		-e 's/([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}/<ip-removed>/g'
		-e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac-removed>/g'
	)
	[ ${#hs} -ge 3 ] && sedargs+=( -e "s/$(printf '%s' "$hs" | sed 's/[][\.*^$/]/\\&/g')/<host-removed>/g" )
	[ ${#u}  -ge 3 ] && [ "$u" != root ] && sedargs+=( -e "s/\\b$(printf '%s' "$u" | sed 's/[][\.*^$/]/\\&/g')\\b/<user-removed>/g" )
	sed "${sedargs[@]}"
}

main() {
	local run_id body clean i masked=0
	run_id="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
	body="$(report_body 2>/dev/null)"
	clean="$(printf '%s\n' "$body" | scrub)"

	# anonymity audit: how many lines did the scrubber have to change?
	local -a A B
	mapfile -t A <<< "$body"; mapfile -t B <<< "$clean"
	for i in "${!A[@]}"; do [ "${A[$i]}" != "${B[$i]}" ] && masked=$((masked+1)); done

	local nok nwarn ninfo
	nok=$(printf '%s\n' "$clean" | grep -c '\[OK\]')
	nwarn=$(printf '%s\n' "$clean" | grep -c '\[WARN\]')
	ninfo=$(printf '%s\n' "$clean" | grep -c '\[INFO\]')

	echo "MongoDB host health report (anonymized, relative values only)"
	echo "tool: mdiag-safe $version   run id: ${run_id:-n/a}"
	echo "legend: [OK] meets generic recommendation, [WARN] deviates, [INFO] informational"
	echo
	echo "== Summary =="
	row "checks" "$nok OK, $nwarn WARN, $ninfo INFO"
	if [ "$masked" -eq 0 ]; then row "anonymity audit" "clean (nothing had to be masked)"
	else row "anonymity audit" "ATTENTION: $masked line(s) had identifying data masked - review before sharing"; fi
	if [ "$nwarn" -gt 0 ]; then
		echo "  items needing attention:"
		printf '%s\n' "$clean" | grep '\[WARN\]' | sed -E 's/^ +/    - /; s/ +\[WARN\] +/ : /' | head -40
	fi
	printf '%s\n' "$clean"
	[ "$masked" -gt 0 ] && exit 3
	exit 0
}

main
