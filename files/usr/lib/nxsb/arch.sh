#!/bin/sh
# nxsb: map the OpenWrt package architecture to the upstream sing-box build name.
# Usage: . /usr/lib/nxsb/arch.sh; nxsb_upstream_arch   -> prints e.g. "armv7", rc 1 if unknown

nxsb_openwrt_arch() {
	local a
	if command -v opkg >/dev/null 2>&1; then
		a="$(opkg print-architecture 2>/dev/null | awk '$2!="all" && $2!="noarch" {print $2; exit}')"
	elif command -v apk >/dev/null 2>&1; then
		a="$(apk --print-arch 2>/dev/null)"
	fi
	[ -n "$a" ] || a="$(grep -m1 '^DISTRIB_ARCH=' /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)"
	[ -n "$a" ] || a="$(uname -m)"
	echo "$a"
}

# $1 = openwrt arch string. Prints upstream build name.
nxsb_map_arch() {
	case "$1" in
		# NOTE: upstream's plain amd64/arm64 builds are glibc-dynamic; OpenWrt is musl -> use the static "-musl" builds
		x86_64|amd64)                                  echo amd64-musl ;;
		i386_pentium4|i386_pentium-mmx|i686|i386)      echo 386 ;;
		i386_i486|geode*)                              echo 386-softfloat ;;
		aarch64*|arm64)                                echo arm64-musl ;;
		arm_cortex-a5*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a15*|arm_cortex-a53*|arm_cortex-a72*|armv7l)
		                                               echo armv7 ;;
		arm_arm1176jzf-s*|arm_arm1136j-s*|arm_mpcore*|armv6l) echo armv6 ;;
		arm_fa526*)                                    return 1 ;;   # ARMv4: no Go build exists
		arm_xscale*|arm_arm926ej-s*|arm_*)             echo armv5 ;;
		mipsel_*|mipsel)                               echo mipsle-softfloat ;;
		mips_*|mips)                                   echo mips-softfloat ;;
		mips64el_*|mips64el)                           echo mips64le-softfloat ;;
		mips64_*|mips64)                               echo mips64-softfloat ;;
		riscv64*)                                      echo riscv64 ;;
		loongarch64*)                                  echo loong64 ;;
		powerpc64*|ppc64le)                            echo ppc64le ;;
		*)                                             return 1 ;;
	esac
}

nxsb_upstream_arch() {
	local oa up
	oa="$(nxsb_openwrt_arch)"
	up="$(nxsb_map_arch "$oa")" || { echo "unsupported architecture: $oa" >&2; return 1; }
	echo "$up"
}
