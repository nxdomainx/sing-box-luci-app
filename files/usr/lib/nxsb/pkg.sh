#!/bin/sh
# nxsb: the router's package manager, opkg (OpenWrt 24.10 and older) or apk (OpenWrt 25.12+).
# Usage: . /usr/lib/nxsb/pkg.sh; pm_version kmod-tun
# Every call answers from the installed-package database directly where it can: the package manager itself
# refuses to run while another instance holds its lock (e.g. inside our own install script).

APK_DB=/lib/apk/db/installed
OPKG_DB=/usr/lib/opkg/status

pm_is_apk() { [ -f $APK_DB ] && command -v apk >/dev/null 2>&1; }
pm_name()   { pm_is_apk && echo apk || echo opkg; }
pm_ext()    { pm_is_apk && echo apk || echo ipk; }

# installed version of a package, empty when not installed
pm_version() {
	if pm_is_apk; then awk -v p="$1" '$0=="P:"p{f=1;next} f&&/^V:/{print substr($0,3);exit} /^$/{f=0}' $APK_DB 2>/dev/null
	else awk -v p="$1" '$1=="Package:"{cur=$2} cur==p && $1=="Version:"{print $2; exit}' $OPKG_DB 2>/dev/null; fi
}

# another install is running (its lock is held)
pm_busy() {
	if pm_is_apk; then [ -n "$(pidof apk)" ]
	else ! opkg list-installed >/dev/null 2>&1; fi
}

pm_update()       { if pm_is_apk; then apk update; else opkg update; fi; }
pm_install()      { if pm_is_apk; then apk add "$@"; else opkg install "$@"; fi; }
# a local package file. apk trusts only packages listed in a signed feed index: a file handed over by the user
# has no such entry, so it is taken as is (its name, arch and kernel build are checked before, see deps.sh)
pm_install_file() { if pm_is_apk; then apk add --allow-untrusted --no-network "$1"; else opkg install "$1"; fi; }
pm_remove()       { if pm_is_apk; then apk del "$@"; else opkg remove "$@"; fi; }

# the per-kernel kmods feed of this exact build (its folder URL), empty when the image has no feed list
pm_kmods_feed() {
	if pm_is_apk; then
		grep -h '/kmods/' /etc/apk/repositories.d/distfeeds.list 2>/dev/null | head -1 | sed 's#/packages\.adb$##'
	else
		local f
		f="$(awk '$2=="openwrt_kmods"{print $3; exit}' /etc/opkg/distfeeds.conf 2>/dev/null)"
		[ -n "$f" ] || f="$(awk '$2=="openwrt_core"{print $3; exit}' /etc/opkg/distfeeds.conf 2>/dev/null)"
		echo "$f"
	fi
}

# file name of a kmod package in that feed. $1 = package, $2 = kernel package version without its ~hash, $3 = arch
#   opkg: kmod-tun_6.6.110-r1_aarch64_cortex-a53.ipk     apk: kmod-tun-6.6.110-r1.apk
pm_kmod_file() { if pm_is_apk; then echo "$1-$2.apk"; else echo "$1_$2_$3.ipk"; fi; }

# what kind of package file $1 is: ipk | apk | (empty)
pm_file_kind() {
	case "$(head -c 4 "$1" 2>/dev/null)" in
		ADB*) echo apk ;;
		*) gzip -t "$1" 2>/dev/null && echo ipk ;;
	esac
}

# pid and every descendant (busybox has no pkill -P): a package manager's own download child must die with it
pm_kill_tree() {
	local p c
	for p in /proc/[0-9]*; do
		c="${p#/proc/}"
		[ "$(awk '{print $4}' $p/stat 2>/dev/null)" = "$1" ] && pm_kill_tree "$c"
	done
	kill "$1" 2>/dev/null
}
