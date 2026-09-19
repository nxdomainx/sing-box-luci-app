#!/bin/sh
# nxsb core manager: fetch the pinned upstream sing-box build for this box, verify, install as /usr/bin/nxsb.
#
#   core.sh install [VERSION]          fetch + verify + install (VERSION defaults to the newest pinned)
#   core.sh upgrade VERSION [SHA256]   same, explicit version; SHA256 needed when VERSION is not pinned
#   core.sh import FILE                install from a local .tar.gz or raw binary (offline)
#   core.sh version                    print installed core version (empty if none)
#   core.sh status                     json: installed, version, pinned, arch
#
# Env / UCI:  mirror = base URL replacing https://github.com/SagerNet/sing-box/releases/download
#             (UCI nxsb.main.mirror or $NXSB_MIRROR). Layout must be <mirror>/v<VER>/<asset>.

BIN=/usr/bin/nxsb
LIB=/usr/lib/nxsb
STATE=/var/run/nxsb
LOG=$STATE/core-install.log      # the install log; core.log is the running core's log mirror
EVENTS=/etc/nxsb/events.log      # service events (persistent: survives a reboot, shown by the Log page and diag)
PINS=$LIB/core-versions
UPSTREAM=https://github.com/SagerNet/sing-box/releases/download

. $LIB/arch.sh
mkdir -p $STATE

log() { echo "$(date '+%F %T') $*" | tee -a $LOG; }
# failures also go to syslog and the service events, so they are still there after the modal is closed or the box rebooted
die() { log "ERROR: $*"; logger -t nxsb "core: $*"; mkdir -p /etc/nxsb; echo "$(date '+%F %T') core: $*" >> $EVENTS; echo "failed" > $STATE/core.state; exit 1; }
# a job killed from outside (out of memory, reboot) must not leave "running" behind forever
_abort() { [ "$(cat $STATE/core.state 2>/dev/null)" = running ] && { log "ERROR: aborted before finishing (killed? out of memory?)"; echo failed > $STATE/core.state; }; rm -rf $STATE/core.lock; }
# one core job at a time; a lock whose owner is gone is taken over
# (the loser must not touch the shared state file or log: they belong to the job that holds the lock)
core_lock() {
	local owner
	if ! mkdir $STATE/core.lock 2>/dev/null; then
		owner="$(cat $STATE/core.lock/pid 2>/dev/null)"
		if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then echo "another core install is running (pid $owner)" >&2; logger -t nxsb "core: another core install is running (pid $owner), not starting a second one"; exit 1; fi
		rm -rf $STATE/core.lock; mkdir $STATE/core.lock 2>/dev/null || { echo "could not take the core lock" >&2; exit 1; }
	fi
	echo $$ > $STATE/core.lock/pid
	echo "running" > $STATE/core.state
	# a signal must end the job (ash would otherwise resume after the trap); exit runs the EXIT trap
	trap '_abort' EXIT; trap 'exit 143' INT TERM
}

mirror() {
	[ -n "$NXSB_MIRROR" ] && { echo "$NXSB_MIRROR"; return; }
	local m; m="$(uci -q get nxsb.main.mirror)"
	echo "${m:-$UPSTREAM}"
}

channel() { local c; c="$(uci -q get nxsb.main.core_channel)"; echo "${c:-pinned}"; }

# newest upstream version for a channel. github.com only (it is what the bootstrap pins cover), no API, no
# rate limit: stable = where /releases/latest redirects to, beta = first entry of the releases feed.
resolve_latest() { # stable|beta -> version on stdout, cached in core.latest
	local tmp v; tmp="$(mktemp)"
	if [ "$1" = beta ]; then
		fetch "https://github.com/SagerNet/sing-box/releases.atom" "$tmp" && v="$(grep -o '<title>[0-9][^<]*</title>' "$tmp" | head -1 | sed 's/<[^>]*>//g')"
	else
		fetch "https://github.com/SagerNet/sing-box/releases/latest" "$tmp" && v="$(grep -o 'releases/tag/v[0-9][0-9A-Za-z.-]*' "$tmp" | head -1 | sed 's#.*/tag/v##')"
	fi
	rm -f "$tmp"
	[ -n "$v" ] || return 1
	echo "$v" > $STATE/core.latest; echo "$v"
}

# pins file is kept in ascending version order; the last entry is the newest
newest_pinned() { awk '!/^#/ && NF==4 {v=$1} END{print v}' $PINS; }
pinned_sha()    { awk -v v="$1" -v a="$2" '!/^#/ && $1==v && $2==a {print $3}' $PINS; }
pinned_size()   { awk -v v="$1" -v a="$2" '!/^#/ && $1==v && $2==a {print $4}' $PINS; }

# cached: running the 70 MB binary costs ~1 s on a small router, and status is polled
installed_version() {
	[ -x $BIN ] || return 0
	if [ -s $STATE/core.version ] && [ ! $BIN -nt $STATE/core.version ]; then cat $STATE/core.version; return 0; fi
	local v; v="$($BIN version 2>/dev/null | awk 'NR==1 && $1=="sing-box" && $2=="version" {print $3}')"
	[ -n "$v" ] && echo "$v" > $STATE/core.version
	echo "$v"
}

# pick a scratch dir with at least $1 KB free; prefer RAM
scratch_dir() {
	local need=$1 d
	for d in /tmp /var/tmp /usr/lib/nxsb; do
		mkdir -p $d 2>/dev/null || continue
		[ "$(df -k $d | awk 'NR==2{print $4}')" -gt "$need" ] && { echo $d; return; }
	done
	return 1
}

fetch() { # url dest  -- uclient-fetch is in every default image; curl only if present. Its own message -> fetch.err
	: > $STATE/fetch.err
	if command -v curl >/dev/null 2>&1; then
		# no silent hang: give up when nothing arrives for 60 s, and cap the whole transfer; -S keeps the error text
		curl -fsSL -S --retry 3 --retry-delay 2 --connect-timeout 20 --speed-limit 512 --speed-time 60 --max-time 900 -o "$2" "$1" 2>$STATE/fetch.err
	else
		uclient-fetch -T 30 -O "$2" "$1" 2>$STATE/fetch.err
	fi
}
fetch_err() { grep -vE '^(Downloading|Writing to|Download completed| *% |Dload)' $STATE/fetch.err 2>/dev/null | grep -v '^ *$' | tail -1 | cut -c1-200; }

install_from_tar() { # tarfile
	local tar=$1 tmpbin
	tmpbin=$BIN.new
	local member
	member="$(tar -tzf "$tar" 2>$STATE/tar.err | grep -E '(^|/)sing-box$' | head -1)"
	[ -n "$member" ] || die "tarball has no sing-box binary: $(tail -1 $STATE/tar.err 2>/dev/null || echo 'not a .tar.gz, or truncated')"
	log "extracting $member"
	# BusyBox tar: -O writes the member to stdout, so the 25MB tarball never needs unpacking to disk
	tar -xzOf "$tar" "$member" > $tmpbin 2>$STATE/tar.err || { rm -f $tmpbin; die "extract failed: $(tail -1 $STATE/tar.err 2>/dev/null || echo 'flash full?')"; }
	install_from_bin $tmpbin
}

# ELF e_machine of a file -> human name (so a wrong-architecture upload gets a clear message)
elf_machine() {
	# e_machine is 2 bytes at offset 18 in the byte order given by EI_DATA (offset 5): 1 = little, 2 = big (mips)
	local d b0 b1 m
	command -v hexdump >/dev/null 2>&1 || { echo skip; return; }        # tiny BusyBox: the version run below still checks
	[ "$(hexdump -n 4 -e '4/1 "%02x"' "$1" 2>/dev/null)" = 7f454c46 ] || { echo "not-elf"; return; }
	d="$(hexdump -s 5 -n 1 -e '1/1 "%d"' "$1" 2>/dev/null)"
	set -- $(hexdump -s 18 -n 2 -e '2/1 "%d "' "$1" 2>/dev/null); b0=$1; b1=$2
	[ -n "$b0" ] && [ -n "$b1" ] || { echo "unknown"; return; }
	if [ "$d" = 2 ]; then m=$((b1 + 256 * b0)); else m=$((b0 + 256 * b1)); fi
	case "$m" in 3) echo i386;; 8) echo mips;; 40) echo arm;; 62) echo x86_64;; 183) echo aarch64;; 243) echo riscv64;; 258) echo loongarch;; *) echo "unknown($m)";; esac
}

install_from_bin() { # path (moved into place)
	local src=$1 v
	chmod 755 "$src"
	local want got; got="$(elf_machine "$src")"
	case "$(uname -m)" in x86_64) want=x86_64;; i?86) want=i386;; aarch64) want=aarch64;; arm*) want=arm;; mips*) want=mips;; riscv64) want=riscv64;; loongarch64) want=loongarch;; *) want="";; esac
	[ "$got" = not-elf ] && { rm -f "$src"; die "not a program file (an HTML page saved as the core?). The Core tab names the right file."; }
	[ -z "$want" ] || [ "$got" = skip ] || [ "$got" = "$want" ] || { rm -f "$src"; die "wrong architecture: this file is for $got, this router is $want ($(uname -m)). The Core tab names the right file."; }
	local vout vrc; vout="$("$src" version 2>&1)"; vrc=$?
	v="$(echo "$vout" | awk 'NR==1 && $1=="sing-box" {print $3}')"
	[ -n "$v" ] || { rm -f "$src"; die "binary does not run on this box (wrong arch/libc?): exit code $vrc$([ $vrc -gt 128 ] && echo " (signal $((vrc - 128)))") $(echo "$vout" | head -1)"; }
	[ "$src" = "$BIN.new" ] || cp "$src" $BIN.new
	# a subscription is stored: the new core must accept today's config before it replaces the old one
	local cfg="$STATE/config.check.json"
	if [ -s /etc/nxsb/subscription.json ] && /etc/init.d/nxsb generate > "$cfg" 2>/dev/null && [ -s "$cfg" ]; then
		local out rc; out="$($BIN.new check -c "$cfg" -D /etc/nxsb 2>&1)"; rc=$?; out="$(echo "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g")"
		[ $rc = 0 ] || {
			rm -f $BIN.new "$cfg"
			die "core $v rejects the current config, keeping $(installed_version): $(echo "$out" | head -2)"
		}
		log "core $v accepts the current config"
	elif [ -s /etc/nxsb/subscription.json ]; then
		log "config could not be generated, compatibility check skipped"
	fi
	rm -f "$cfg"
	# rename, not copy: a third 75 MB would not fit on many overlays
	[ -x $BIN.new ] || die "the new core vanished before it could be installed (another job or a service restart removed it)"
	local prev=""; if [ -x $BIN ]; then prev="$(installed_version)"; mv -f $BIN $BIN.prev 2>/dev/null; fi
	mv -f $BIN.new $BIN || { [ -x $BIN.prev ] && mv -f $BIN.prev $BIN; die "could not move the new core into place"; }
	log "installed core $v at $BIN"
	echo "$v" > $STATE/core.version; touch -r $BIN $STATE/core.version 2>/dev/null
	# restart the service if it was running; if it does not come back AND STAY UP, put the previous core back
	# (a core that starts and dies is respawned by procd, so a single "running" sample is not proof)
	if /etc/init.d/nxsb running 2>/dev/null; then
		log "restarting service"
		/etc/init.d/nxsb restart; sleep 8
		local p1 p2; p1="$(pidof nxsb | cut -d' ' -f1)"; sleep 7; p2="$(pidof nxsb | cut -d' ' -f1)"
		if ! /etc/init.d/nxsb running 2>/dev/null || [ -z "$p1" ] || [ "$p1" != "$p2" ]; then
			if [ -n "$prev" ] && [ -x $BIN.prev ]; then
				log "service did not come back with core $v, rolling back to $prev"
				logger -t nxsb "core $v failed to start, rolled back to $prev"
				mkdir -p /etc/nxsb; echo "$(date '+%F %T') core $v failed to start, rolled back to $prev" >> $EVENTS
				mv -f $BIN.prev $BIN; echo "$prev" > $STATE/core.version
				/etc/init.d/nxsb restart
			fi
			die "core $v did not start"
		fi
	fi
	rm -f $BIN.prev
	echo "done" > $STATE/core.state
}

do_install() { # [version] [sha256]
	local ver=$1 sha=$2 arch url need dir tar got size rc ch
	core_lock
	arch="$(nxsb_upstream_arch)" || die "cannot map architecture $(nxsb_openwrt_arch)"
	ch="$(channel)"
	[ "$(date +%Y)" -lt 2024 ] 2>/dev/null && log "WARNING clock not set (year $(date +%Y)): TLS downloads fail until NTP syncs"
	$LIB/deps.sh unpoison on
	if [ -z "$ver" ] && [ "$ch" != pinned ]; then
		if ver="$(resolve_latest "$ch")"; then log "newest $ch release: $ver"
		else log "could not look up the newest $ch release, using the pinned $(newest_pinned)"; fi
	fi
	[ -n "$ver" ] || ver="$(newest_pinned)"
	[ -n "$sha" ] || sha="$(pinned_sha "$ver" "$arch")"
	if [ -z "$sha" ]; then
		# pinned channel is strict; a channel that follows upstream has no checksum table by nature
		[ "$ch" != pinned ] || { $LIB/deps.sh unpoison off; die "version $ver has no pinned checksum for $arch; pass the sha256 explicitly"; }
		log "no pinned checksum for $ver ($ch channel): relying on GitHub TLS plus the binary checks"
	fi
	size="$(pinned_size "$ver" "$arch")"
	log "arch=$(nxsb_openwrt_arch) -> upstream=$arch version=$ver"

	# space: tarball (~30MB) in scratch, binary (~75MB) + tmp copy on the target fs
	need=$(( ${size:-32000000} / 1024 + 2048 ))
	dir="$(scratch_dir $need)" || { $LIB/deps.sh unpoison off; die "no scratch space for the download (need ${need}KB)"; }
	local binfs_free; binfs_free=$(df -k "$(dirname $BIN)" | awk 'NR==2{print $4}')
	# scratch on the same filesystem as the binary: both must fit at once
	[ "$(df -k "$dir" | awk 'NR==2{print $1}')" = "$(df -k "$(dirname $BIN)" | awk 'NR==2{print $1}')" ] && need=$((need + 90000)) || need=90000
	[ "$binfs_free" -gt "$need" ] || { $LIB/deps.sh unpoison off; die "not enough free space on $(dirname $BIN): ${binfs_free}KB, need ~$((need / 1024))MB"; }

	url="$(mirror)/v$ver/sing-box-$ver-linux-$arch.tar.gz"
	tar="$dir/nxsb-core-$ver-$arch.tar.gz"
	# whatever happens (die, kill): no tarball left on flash, no hostname pins left behind
	trap 'rm -f "$tar"; $LIB/deps.sh unpoison off; _abort' EXIT
	log "downloading $url"
	fetch "$url" "$tar"; rc=$?
	$LIB/deps.sh unpoison off
	[ $rc = 0 ] || { rm -f "$tar"; die "download failed (rc=$rc): $(fetch_err)$([ -z "$(fetch_err)" ] && echo 'no details from the downloader; no internet, DNS poisoned, or the mirror is down')"; }
	if [ -n "$sha" ]; then
		got="$(sha256sum "$tar" | awk '{print $1}')"
		[ "$got" = "$sha" ] || { rm -f "$tar"; die "checksum mismatch: got $got want $sha"; }
		log "checksum ok"
	fi
	install_from_tar "$tar"
	rm -f "$tar"
}

# cron: follow the channel (stable/beta) once a day; pinned never moves on its own
check_update() {
	local ch cur v; ch="$(channel)"
	[ "$ch" != pinned ] || return 0
	cur="$(installed_version)"
	$LIB/deps.sh unpoison on; v="$(resolve_latest "$ch")"; rc=$?; $LIB/deps.sh unpoison off
	[ $rc = 0 ] || { log "update check: could not look up the newest $ch release ($(fetch_err))"; return 1; }
	[ "$v" != "$cur" ] || { log "update check: $cur is the newest $ch release"; return 0; }
	log "update check: $cur -> $v ($ch)"
	do_install "$v"
}

case "$1" in
	install) do_install "$2" ;;
	check-update) check_update ;;
	latest) $LIB/deps.sh unpoison on; resolve_latest "${2:-$(channel)}"; rc=$?; $LIB/deps.sh unpoison off; exit $rc ;;
	upgrade) [ -n "$2" ] || die "upgrade needs a version"; do_install "$2" "$3" ;;
	import)
		[ -f "$2" ] || die "no such file: $2"
		core_lock
		bf=$(df -k "$(dirname $BIN)" | awk 'NR==2{print $4}'); [ "${bf:-0}" -gt 90000 ] || die "not enough free space on $(dirname $BIN): ${bf:-?}KB, need ~90MB"
		case "$2" in
			*.tar.gz|*.tgz) install_from_tar "$2" ;;
			*) install_from_bin "$2" ;;
		esac ;;
	version) installed_version ;;
	guide)
		oa="$(nxsb_openwrt_arch)"; up="$(nxsb_map_arch "$oa" 2>/dev/null)"; v="$(newest_pinned)"
		printf '{"openwrt_arch":"%s","upstream_arch":"%s","version":"%s","file":"%s","url":"%s","release":"%s","note":"%s"}\n' \
			"$oa" "${up:-unknown}" "$v" \
			"$([ -n "$up" ] && echo "sing-box-$v-linux-$up.tar.gz")" \
			"$([ -n "$up" ] && echo "$(mirror)/v$v/sing-box-$v-linux-$up.tar.gz")" \
			"https://github.com/SagerNet/sing-box/releases/tag/v$v" \
			"$(case "$up" in amd64-musl|arm64-musl) echo "use the -musl build: the plain $(echo $up | sed s/-musl//) build is glibc-linked and will not run on OpenWrt";; "") echo "architecture $oa is not in the table; pick the build matching uname -m ($(uname -m))";; *) echo "";; esac)" ;;
	status)
		v="$(installed_version)"
		printf '{"installed":%s,"version":"%s","pinned":"%s","channel":"%s","latest":"%s","openwrt_arch":"%s","upstream_arch":"%s","state":"%s"}\n' \
			"$([ -n "$v" ] && echo true || echo false)" "$v" "$(newest_pinned)" "$(channel)" "$(cat $STATE/core.latest 2>/dev/null)" \
			"$(nxsb_openwrt_arch)" "$(nxsb_map_arch "$(nxsb_openwrt_arch)" 2>/dev/null)" \
			"$(cat $STATE/core.state 2>/dev/null)" ;;
	*) echo "usage: $0 install [VERSION] | upgrade VERSION [SHA256] | import FILE | check-update | latest [stable|beta] | version | status" >&2; exit 2 ;;
esac
