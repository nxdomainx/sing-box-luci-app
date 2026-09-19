#!/bin/sh
# nxsb: router IPv6 DNS advertisement (RA RDNSS + DHCPv6 DNS option).
#   dns6.sh off       stop advertising, remember the originals (nxsb.main.dns6_saved "section:ra_dns:dns_service")
#   dns6.sh on        advertise (ra_dns + dns_service = 1), originals remembered the same way
#   dns6.sh restore   put the originals back (uninstall)
#   dns6.sh apply     on if nxsb.main.lan_dns6 = 1, else off
# Windows lists the router's IPv6 DNS address before the IPv4 one and sing-box's local resolver tries servers in
# order with a 5 s timeout: on a LAN where the IPv6 leg is bad every lookup stalls. The router offers nothing over
# IPv6 DNS that IPv4 does not. Turned off at install and kept off until the user enables it (Settings » LAN).
_event() { logger -t nxsb "$*"; [ -d /var/run/nxsb ] && echo "$(date '+%F %T') $*" >> /etc/nxsb/events.log; }
# _dns6_set 0|1: force both options on every RA/DHCPv6-serving section, remembering what was there the first time
_dns6_set() {
	local want=$1 s saved="" cur r d secs
	saved="$(uci -q get nxsb.main.dns6_saved)"
	secs="$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([a-zA-Z0-9_]*\)\.\(ra\|dhcpv6\)='server'$/\1/p" | sort -u)"
	if [ -z "$secs" ] && [ "$want" = 1 ]; then
		secs=lan; _event "IPv6 RA/DHCPv6 is off on this router (Network » Interfaces » lan » IPv6): the DNS option has no effect until it is on"
	fi
	for s in $secs; do
		r="$(uci -q get dhcp.$s.ra_dns)"; d="$(uci -q get dhcp.$s.dns_service)"
		[ "$r" = "$want" ] && [ "$d" = "$want" ] && continue
		echo "$saved" | grep -q "\(^\| \)$s:" || saved="$saved $s:$r:$d"
		uci set dhcp.$s.ra_dns=$want; uci set dhcp.$s.dns_service=$want; cur=1
	done
	[ -n "$cur" ] || return 0
	uci set nxsb.main.dns6_saved="$(echo $saved)"; uci commit nxsb; uci commit dhcp
	/etc/init.d/odhcpd reload >/dev/null 2>&1
	_event "IPv6 DNS advertisement $([ "$want" = 1 ] && echo on || echo off) ($(echo $secs))"
}
_dns6_off() { _dns6_set 0; }
_dns6_on()  { _dns6_set 1; }
_dns6_restore() {
	local e s r d saved; saved="$(uci -q get nxsb.main.dns6_saved)"
	[ -n "$saved" ] || return 0
	for e in $saved; do
		s="${e%%:*}"; e="${e#*:}"; r="${e%%:*}"; d="${e#*:}"
		if [ -n "$r" ]; then uci set dhcp.$s.ra_dns="$r"; else uci -q delete dhcp.$s.ra_dns; fi
		if [ -n "$d" ]; then uci set dhcp.$s.dns_service="$d"; else uci -q delete dhcp.$s.dns_service; fi
	done
	uci -q delete nxsb.main.dns6_saved; uci commit nxsb; uci commit dhcp
	/etc/init.d/odhcpd reload >/dev/null 2>&1
	_event "IPv6 DNS advertisement restored"
}


case "$1" in
	off) _dns6_off ;;
	on) _dns6_on ;;
	restore) _dns6_restore ;;
	apply) if [ "$(uci -q get nxsb.main.lan_dns6)" = 1 ]; then _dns6_on; else _dns6_off; fi ;;
	*) echo "usage: $0 off | on | restore | apply" >&2; exit 2 ;;
esac
