#!/bin/sh
# nxsb dependency helper. Iranian ISPs poison DNS for downloads.openwrt.org / github.com (the IP+SNI path is
# open), so for the duration of a download the hostnames are pinned to known addresses (bootstrap-hosts).
#
#   deps.sh unpoison on|off       pin/unpin the download hostnames (no-op without dnsmasq)
#   deps.sh kmod [tun|bbr|all]    opkg update + install kmod-tun / kmod-tcp-bbr (through the unpoisoned resolver)
#   deps.sh bbr apply             congestion control as set in Settings » Core (bbr when the module is there)
#   deps.sh status                json: tun device present, kmod-tun installed, bbr wanted/installed/active
#   deps.sh guide [tun|bbr]       json: exact kmod ipk for this router (feed dir, file name, url)
#   deps.sh import FILE           install an uploaded kmod-tun or kmod-tcp-bbr ipk
LIB=/usr/lib/nxsb
STATE=/var/run/nxsb
EVENTS=/etc/nxsb/events.log
mkdir -p $STATE
log() { echo "$(date '+%F %T') $*" | tee -a $STATE/deps.log; }
# failures also go to syslog and the service events: still there after the modal is closed or the box rebooted
logfail() { log "$*"; logger -t nxsb "modules: $*"; mkdir -p /etc/nxsb; echo "$(date '+%F %T') modules: $*" >> $EVENTS; }
# a job killed from outside (out of memory, reboot) must not leave "running" behind forever
_abort() { [ "$(cat $STATE/deps.state 2>/dev/null)" = running ] && { log "ERROR: aborted before finishing (killed? out of memory?)"; echo failed > $STATE/deps.state; }; }

HOSTSFILE=/tmp/hosts/nxsb-bootstrap
PROBE_downloads_openwrt_org="https://downloads.openwrt.org/releases/"
PROBE_github_com="https://github.com/SagerNet/sing-box/releases"
# hosts-file changes only need a HUP (dnsmasq re-reads addn-hosts); a conf-dir change needs a restart
_dnsmasq_reload() { [ -n "$(pidof dnsmasq)" ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1; sleep 1; }
_dnsmasq_hup() { [ -n "$(pidof dnsmasq)" ] && kill -HUP $(pidof dnsmasq) 2>/dev/null; sleep 1; }
_probe() { uclient-fetch -q -O /dev/null -T 6 "$1" >/dev/null 2>&1; }
# opkg's own fetch has no timeout: a poisoned or blackholed address would hang it forever
# (BusyBox on most images has no timeout applet, so: run in background, kill after 300 s, plus opkg's wget child)
_to() {
	local pid n=0 c
	"$@" & pid=$!
	while kill -0 $pid 2>/dev/null; do
		if [ $n -ge 300 ]; then
			for c in $(ps w 2>/dev/null | awk '/[o]pkg-[A-Za-z0-9]+\// {print $1}'); do kill $c 2>/dev/null; done
			kill $pid 2>/dev/null; sleep 1; kill -9 $pid 2>/dev/null; log "gave up after 300 s: $1 $2"; return 124
		fi
		sleep 1; n=$((n+1))
	done
	wait $pid
}

# Pin each poisoned hostname to a working address: try the candidates from bootstrap-hosts in order, then the
# plain-UDP resolver bypass (server=/host/8.8.8.8). A host that resolves fine without help is left alone.
unpoison_on() {
	[ -x /etc/init.d/dnsmasq ] || return 0
	# one download at a time: a second caller waits for the first one's "unpoison off"; a lock whose owner is gone
	# is taken over at once (the owner pid is the parent job, written into the lock dir)
	local n=0 owner
	until mkdir $STATE/unpoison.lock 2>/dev/null; do
		owner="$(cat $STATE/unpoison.lock/pid 2>/dev/null)"
		[ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null && { rm -rf $STATE/unpoison.lock; continue; }
		sleep 1; n=$((n+1)); [ $n -ge 900 ] && { rm -rf $STATE/unpoison.lock; break; }
	done
	# owner = the job: the script itself when called inline (kmod/import), else the caller (core.sh runs us as a child)
	echo "${UNPOISON_OWNER:-${PPID:-$$}}" > $STATE/unpoison.lock/pid 2>/dev/null
	mkdir -p /tmp/hosts; : > $HOSTSFILE
	local h ip url ok
	for h in downloads.openwrt.org github.com; do
		eval url=\$PROBE_$(echo $h | tr .- __)
		ok=0
		_probe "$url" && { log "$h reachable as-is"; continue; }
		for ip in $(awk -v h="$h" '!/^#/ && $2==h {print $1}' $LIB/bootstrap-hosts); do
			grep -v " $h\$" $HOSTSFILE > $HOSTSFILE.tmp 2>/dev/null; echo "$ip $h" >> $HOSTSFILE.tmp; mv -f $HOSTSFILE.tmp $HOSTSFILE
			_dnsmasq_hup
			if _probe "$url"; then log "$h pinned to $ip"; ok=1; break; fi
		done
		[ $ok = 1 ] && continue
		grep -v " $h\$" $HOSTSFILE > $HOSTSFILE.tmp 2>/dev/null; mv -f $HOSTSFILE.tmp $HOSTSFILE
		mkdir -p "$(_confdir)"; echo "server=/$h/8.8.8.8" >> "$(_confdir)/nxsb-unpoison.conf"; _dnsmasq_reload
		if _probe "$url"; then log "$h via resolver bypass (8.8.8.8)"; else logfail "WARNING: $h unreachable by every method (no internet, or everything is blocked)"; fi
	done
	# the GitHub asset hosts share Fastly with github.com's pins: pin them all, harmless if unused
	for h in objects.githubusercontent.com release-assets.githubusercontent.com raw.githubusercontent.com; do
		grep -q " $h\$" $HOSTSFILE || awk -v h="$h" '!/^#/ && $2==h {print $1, $2; exit}' $LIB/bootstrap-hosts >> $HOSTSFILE
	done
	_dnsmasq_hup
}
# only the job that holds the lock may take the pins down (a core download and a module install can overlap)
unpoison_off() {
	local f changed=0 owner
	owner="$(cat $STATE/unpoison.lock/pid 2>/dev/null)"
	if [ -n "$owner" ] && [ "$owner" != 1 ] && [ "$owner" != "${UNPOISON_OWNER:-${PPID:-$$}}" ] && [ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null; then return 0; fi
	rm -rf $STATE/unpoison.lock
	[ -f $HOSTSFILE ] && { rm -f $HOSTSFILE; changed=1; }
	for f in /tmp/dnsmasq.d/nxsb-unpoison.conf /tmp/dnsmasq.*.d/nxsb-unpoison.conf; do [ -f "$f" ] && { rm -f "$f"; changed=1; }; done
	[ $changed = 1 ] && _dnsmasq_reload
	return 0
}
_confdir() { local d; d="$(grep -h '^conf-dir=' /var/etc/dnsmasq.conf.* 2>/dev/null | head -1 | cut -d= -f2)"; echo "${d:-/tmp/dnsmasq.d}"; }

# read the opkg status db directly: opkg refuses to run while another opkg holds the lock (e.g. inside our postinst)
_pkg_version() { awk -v p="$1" '$1=="Package:"{cur=$2} cur==p && $1=="Version:"{print $2; exit}' /usr/lib/opkg/status 2>/dev/null; }
_opkg_busy() { ! opkg list-installed >/dev/null 2>&1; }

# installed = module file on disk (or built into the kernel); a module merely loaded in RAM is gone after a reboot
tun_installed() { ls /lib/modules/*/tun.ko >/dev/null 2>&1 || grep -q "^tun " /lib/modules/$(uname -r)/modules.builtin 2>/dev/null || [ -n "$(grep -l "^tun" /etc/modules.d/* 2>/dev/null)" ]; }
tun_present() { tun_installed || return 1; [ -c /dev/net/tun ] || modprobe tun >/dev/null 2>&1; [ -c /dev/net/tun ]; }

# BBR congestion control for the router's own TCP, i.e. the upload leg of every tunnel connection (a call's audio and
# video ride inside it with TCP-based protocols). On unless turned off in Settings » Core; needs kmod-tcp-bbr, which
# comes from the same per-kernel kmods feed as kmod-tun. Without the module nothing changes: cubic stays.
BBR_SYSCTL=/etc/sysctl.d/99-nxsb-bbr.conf
BBR_AUTOLOAD=/etc/modules.d/99-nxsb-bbr
bbr_wanted()    { [ "$(uci -q get nxsb.main.bbr)" != 0 ]; }
bbr_installed() { ls /lib/modules/*/tcp_bbr.ko >/dev/null 2>&1 || grep -q "tcp_bbr" /lib/modules/$(uname -r)/modules.builtin 2>/dev/null; }
bbr_available() { grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; }
bbr_current()   { cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; }
bbr_builtin()   { grep -q "tcp_bbr" /lib/modules/$(uname -r)/modules.builtin 2>/dev/null; }
# set the congestion control now; sysctl applet or not, the result is what counts
bbr_set() { [ "$(bbr_current)" = "$1" ] || sysctl -w net.ipv4.tcp_congestion_control="$1" >/dev/null 2>&1 || ( echo "$1" > /proc/sys/net/ipv4/tcp_congestion_control ) 2>/dev/null; [ "$(bbr_current)" = "$1" ]; }
# an autoload entry other than ours (the OpenWrt package ships /etc/modules.d/tcp-bbr)
bbr_autoload_other() { grep -ls '^tcp_bbr' /etc/modules.d/* 2>/dev/null | grep -qv "^$BBR_AUTOLOAD\$"; }
bbr_apply() {
	if bbr_wanted; then
		if ! bbr_installed; then rm -f $BBR_SYSCTL $BBR_AUTOLOAD; return 1; fi
		bbr_available || modprobe tcp_bbr >/dev/null 2>&1
		bbr_available || { rm -f $BBR_SYSCTL $BBR_AUTOLOAD; log "tcp_bbr module does not load"; return 1; }
		# across reboots: the OpenWrt package ships an autoload entry and /etc/sysctl.d/12-tcp-bbr.conf; images
		# with the module built in have neither, so keep our own (99 wins over 12 either way)
		mkdir -p /etc/sysctl.d
		printf '# nxsb: BBR congestion control (Settings » Core)\nnet.ipv4.tcp_congestion_control=bbr\n' > $BBR_SYSCTL
		if bbr_builtin || bbr_autoload_other; then rm -f $BBR_AUTOLOAD; else echo tcp_bbr > $BBR_AUTOLOAD; fi
		bbr_set bbr || { log "could not switch the congestion control to bbr"; return 1; }
	else
		# off: the kernel default, held across reboots even though the module package's own sysctl file says bbr
		rm -f $BBR_AUTOLOAD
		if [ -f /etc/sysctl.d/12-tcp-bbr.conf ]; then mkdir -p /etc/sysctl.d; printf '# nxsb: BBR turned off in Settings » Core\nnet.ipv4.tcp_congestion_control=cubic\n' > $BBR_SYSCTL; else rm -f $BBR_SYSCTL; fi
		[ "$(bbr_current)" = bbr ] && bbr_set cubic
	fi
	return 0
}
# remember that kmod-tcp-bbr was put there by this app (a real removal takes it away again, see postrm).
# A file, not uci: a uci commit from a background job would publish whatever the Settings page has staged.
# "Destroy working directory" leaves this file alone.
BBR_MARK=/etc/nxsb/kmod-tcp-bbr.installed-by-nxsb
bbr_mark_ours() { mkdir -p /etc/nxsb; touch $BBR_MARK; }

# $1: tun (kmod-tun only) | bbr (kmod-tcp-bbr only) | all (default: whatever is missing, bbr only if wanted)
kmod() {
	local what="${1:-all}" need_tun=0 need_bbr=0 rc=0
	UNPOISON_OWNER=$$
	echo running > $STATE/deps.state
	trap '_abort' EXIT; trap 'exit 143' INT TERM
	case "$what" in tun|all) if tun_present; then log "tun device present"; else need_tun=1; fi ;; esac
	case "$what" in bbr) bbr_installed && log "BBR module present" || need_bbr=1 ;;
	                all) if bbr_wanted; then bbr_installed && log "BBR module present" || need_bbr=1; fi ;; esac
	if [ $need_tun = 0 ] && [ $need_bbr = 0 ]; then bbr_apply; echo done > $STATE/deps.state; return 0; fi
	# the pins and the lock are ours only from here on (a concurrent core download may own them until then)
	trap 'unpoison_off; _abort' EXIT
	unpoison_on
	log "opkg update"
	if ! _to opkg update >$STATE/opkg.log 2>&1; then log "opkg update failed: $(grep -m1 -E 'Collected|Cannot|Failed|error|not found' -A1 $STATE/opkg.log | tail -1)"; fi
	if [ $need_tun = 1 ]; then
		log "opkg install kmod-tun"
		if _to opkg install kmod-tun >>$STATE/opkg.log 2>&1 && tun_present; then log "kmod-tun installed"
		elif [ -n "$(_pkg_version kmod-tun)" ]; then logfail "kmod-tun is installed but /dev/net/tun is still missing: reboot the router"; rc=1
		else logfail "kmod-tun install failed: $(grep -m1 -E 'Collected|Cannot|Failed|error|not found' -A1 $STATE/opkg.log | tail -1)"; rc=1; fi
		# the user may already have pressed "Enable & start" while the module was still on its way
		if [ $rc = 0 ] && [ "$(uci -q get nxsb.main.enabled)" = 1 ] && ! /etc/init.d/nxsb running 2>/dev/null; then
			log "service is enabled and was waiting for the module: starting it"; /etc/init.d/nxsb start >/dev/null 2>&1
		fi
	fi
	if [ $need_bbr = 1 ]; then
		log "opkg install kmod-tcp-bbr"
		if _to opkg install kmod-tcp-bbr >>$STATE/opkg.log 2>&1 && bbr_installed; then
			bbr_mark_ours
			if ! bbr_wanted; then log "kmod-tcp-bbr installed; BBR is turned off in Settings » Core"
			elif bbr_apply; then log "kmod-tcp-bbr installed, BBR active"
			else log "kmod-tcp-bbr installed, but BBR could not be switched on (see above); Overview » BBR » Activate retries"; fi
		else
			logfail "kmod-tcp-bbr install failed: $(grep -m1 -E 'Collected|Cannot|Failed|error|not found' -A1 $STATE/opkg.log | tail -1)"
			[ "$what" = bbr ] && rc=1 || log "BBR stays off (uploads and calls work without it, just less smoothly); Settings » Core » BBR module"
		fi
	fi
	unpoison_off
	[ $rc = 0 ] && echo done > $STATE/deps.state || echo failed > $STATE/deps.state
	return $rc
}

# The ipk must come from the kmods feed of this exact kernel build: distfeeds.conf carries that URL (24.10+
# openwrt_kmods; older releases keep kmods in openwrt_core). File name = <pkg>_<kernel>-r<rev>_<arch>.ipk.
# $1: tun (default) | bbr
guide() {
	local feed kver arch file pkg
	case "$1" in bbr|tcp-bbr|kmod-tcp-bbr) pkg=kmod-tcp-bbr ;; *) pkg=kmod-tun ;; esac
	feed="$(awk '$2=="openwrt_kmods"{print $3; exit}' /etc/opkg/distfeeds.conf 2>/dev/null)"
	[ -n "$feed" ] || feed="$(awk '$2=="openwrt_core"{print $3; exit}' /etc/opkg/distfeeds.conf 2>/dev/null)"
	# image built without distfeeds.conf: point at the release's kmods parent folder (the per-kernel subfolder
	# name carries a hash we cannot know offline; the user picks the one matching uname -r)
	[ -n "$feed" ] || feed="$(. /etc/os-release 2>/dev/null; v="${VERSION_ID:-${OPENWRT_RELEASE#OpenWrt }}"; v="${v%% *}"; [ -n "$v" ] && [ -n "$OPENWRT_BOARD" ] && echo "https://downloads.openwrt.org/releases/$v/targets/$OPENWRT_BOARD/kmods")"
	kver="$(_pkg_version kernel | sed 's/~[0-9a-f]*//')"
	[ -n "$kver" ] || kver="$(uname -r)-r1"
	arch="$(. /etc/os-release 2>/dev/null; echo "$OPENWRT_ARCH")"
	[ -n "$arch" ] || arch="$(opkg print-architecture 2>/dev/null | awk 'END{print $2}')"
	file="${pkg}_${kver}_${arch}.ipk"
	printf '{"pkg":"%s","feed":"%s","file":"%s","url":"%s","kernel":"%s","arch":"%s","release":"%s"}\n' \
		"$pkg" "$feed" "$file" "$(case "$feed" in */kmods|*/packages) ;; ?*) echo "$feed/$file";; esac)" "$(uname -r)" "$arch" "$(. /etc/os-release 2>/dev/null; echo "$OPENWRT_RELEASE")"
}

# uploaded ipk: check it really is kmod-tun or kmod-tcp-bbr before handing it to opkg (which then enforces the
# kernel build match)
import_ipk() {
	local f="$1" ctl pkg arch want_arch kdep kver g
	UNPOISON_OWNER=$$
	echo running > $STATE/deps.state
	trap '_abort' EXIT; trap 'exit 143' INT TERM
	[ -s "$f" ] || { log "no file uploaded"; echo failed > $STATE/deps.state; return 1; }
	ctl="$( (tar -xzOf "$f" ./control.tar.gz 2>/dev/null || tar -xzOf "$f" control.tar.gz 2>/dev/null) | tar -xzO ./control 2>/dev/null)"
	pkg="$(echo "$ctl" | sed -n 's/^Package: //p')"
	if [ -z "$pkg" ]; then logfail "not an ipk (no control file inside): $(basename "$f")"; echo failed > $STATE/deps.state; return 1; fi
	case "$pkg" in kmod-tun) g=tun ;; kmod-tcp-bbr) g=bbr ;; *) logfail "this ipk is '$pkg', not kmod-tun or kmod-tcp-bbr"; echo failed > $STATE/deps.state; return 1 ;; esac
	# opkg segfaults on a foreign-arch ipk instead of refusing it: check arch and kernel build here
	arch="$(echo "$ctl" | sed -n 's/^Architecture: //p')"; want_arch="$(. /etc/os-release 2>/dev/null; echo "$OPENWRT_ARCH")"
	if [ -n "$want_arch" ] && [ "$arch" != "$want_arch" ]; then
		logfail "wrong build: this ipk is for $arch, this router is $want_arch"
		log "get $(guide $g | sed -n 's/.*"file":"\([^"]*\)".*/\1/p') instead"; echo failed > $STATE/deps.state; return 1
	fi
	kdep="$(echo "$ctl" | sed -n 's/.*kernel (= \([^)]*\)).*/\1/p')"; kver="$(_pkg_version kernel)"
	if [ -n "$kdep" ] && [ -n "$kver" ] && [ "$kdep" != "$kver" ]; then
		logfail "wrong kernel build: this ipk wants kernel $kdep, this router runs $kver"
		log "get $(guide $g | sed -n 's/.*"file":"\([^"]*\)".*/\1/p') instead"; echo failed > $STATE/deps.state; return 1
	fi
	log "opkg install $(basename "$f")"
	if opkg install "$f" >$STATE/opkg.log 2>&1; then
		if [ $g = tun ] && tun_present; then log "kmod-tun installed"; bbr_apply; echo done > $STATE/deps.state; return 0; fi
		[ $g = bbr ] && bbr_installed && bbr_mark_ours
		if [ $g = bbr ] && bbr_installed; then
			if ! bbr_wanted; then log "kmod-tcp-bbr installed; BBR is turned off in Settings » Core"
			elif bbr_apply; then log "kmod-tcp-bbr installed, BBR active"
			else log "kmod-tcp-bbr installed, but BBR could not be switched on (see above); Overview » BBR » Activate retries"; fi
			echo done > $STATE/deps.state; return 0
		fi
	fi
	logfail "install failed: $(grep -v '^ *$' $STATE/opkg.log | tail -1 | sed 's/^ *\* *//')"
	log "the ipk must be the one from this router's own kmods feed ($(guide $g | sed -n 's/.*"file":"\([^"]*\)".*/\1/p'))"
	echo failed > $STATE/deps.state; return 1
}

# from postinst: opkg is locked by the install that is running us, so the module install has to happen after it
# exits. Fully detached (all fds closed) so opkg does not wait on us.
kmod_deferred() {
	echo running > $STATE/deps.state
	log "module install queued until the running opkg finishes"
	( n=0; while { pidof opkg >/dev/null 2>&1 || _opkg_busy; } && [ $n -lt 1800 ]; do sleep 2; n=$((n+1)); [ $((n % 30)) = 0 ] && echo running > $STATE/deps.state; done; $LIB/deps.sh kmod all ) </dev/null >/dev/null 2>>$STATE/deps.log &
	echo $! > $STATE/deps.pid
}

case "$1" in
	unpoison) case "$2" in on) unpoison_on ;; off) unpoison_off ;; *) exit 2 ;; esac ;;
	kmod) kmod "$2" ;;
	kmod-deferred) kmod_deferred ;;
	bbr) case "$2" in apply) bbr_apply ;; *) exit 2 ;; esac ;;
	guide) guide "$2" ;;
	import) import_ipk "$2" ;;
	status)
		printf '{"tun":%s,"kmod_tun":%s,"bbr_wanted":%s,"bbr_installed":%s,"bbr_active":%s,"congestion":"%s","state":"%s"}\n' \
			"$(tun_installed && [ -c /dev/net/tun ] && echo true || echo false)" \
			"$([ -n "$(_pkg_version kmod-tun)" ] && echo true || echo false)" \
			"$(bbr_wanted && echo true || echo false)" "$(bbr_installed && echo true || echo false)" \
			"$([ "$(bbr_current)" = bbr ] && echo true || echo false)" "$(bbr_current)" \
			"$(cat $STATE/deps.state 2>/dev/null)" ;;
	*) echo "usage: $0 unpoison on|off | kmod [tun|bbr|all] | kmod-deferred | bbr apply | guide [tun|bbr] | import FILE | status" >&2; exit 2 ;;
esac
