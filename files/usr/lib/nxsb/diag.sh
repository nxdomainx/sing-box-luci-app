#!/bin/sh
# nxsb diagnostics: plain checks with the fix on the same line, then details. Safe to paste into a support
# chat: the subscription link is cut down to its host, the API secret is never printed.
RUN=/var/run/nxsb; LIB=/usr/lib/nxsb; BIN=/usr/bin/nxsb; DATA=/etc/nxsb
# subscription state lives in /etc/nxsb/sub.json (older builds: uci)
subst() { [ -s $DATA/sub.json ] && jsonfilter -i $DATA/sub.json -e "@.$1" 2>/dev/null || uci -q get nxsb.main.sub_$1; }
ok()   { echo "OK    $*"; }
warn() { echo "WARN  $*"; }
fail() { echo "FAIL  $*"; }
u() { uci -q get nxsb.main.$1; }
# answer address for $1 from resolver $2 (host or host:port); skips the "Server/Address" header of nslookup
lookup() { nslookup "$1" "$2" 2>/dev/null | awk '/^Name/ {f=1} f && /^Address/ {print $2; exit}' | sed 's/:53$//'; }
rel="$(. /etc/os-release 2>/dev/null; echo "$OPENWRT_RELEASE ($OPENWRT_BOARD)")"
echo "nxsb $(cat $LIB/VERSION 2>/dev/null) on $rel $(uname -m), $(date '+%F %T')"
echo

# ---- core / module ----
v="$($LIB/core.sh version 2>/dev/null)"
[ -n "$v" ] && ok "core installed: sing-box $v" || fail "core not installed. Settings » Core » Download, or Upload from PC"
if [ -c /dev/net/tun ]; then ok "TUN device present"; else fail "no /dev/net/tun. Settings » Core » TUN module » Download, or Upload from PC"; fi
if ls /lib/modules/*/tun.ko >/dev/null 2>&1 || grep -q "^tun " /lib/modules/$(uname -r)/modules.builtin 2>/dev/null; then ok "kmod-tun on disk (survives a reboot)"
else warn "kmod-tun is not installed on disk: after a reboot the service will not start. Settings » Core » TUN module"; fi
cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
if [ "$(u bbr)" != 0 ]; then
	if [ "$cc" = bbr ]; then ok "BBR congestion control active"
	elif ls /lib/modules/*/tcp_bbr.ko >/dev/null 2>&1 || grep -q tcp_bbr /lib/modules/$(uname -r)/modules.builtin 2>/dev/null; then warn "BBR module installed but $cc is in use: Overview » BBR » Activate"
	else warn "BBR module missing ($cc in use): Settings » Core » BBR module » Download, or Upload from PC. Uploads and calls work without it, just less smoothly"; fi
else ok "BBR off (Settings » Core), $cc in use"; fi

# ---- config ----
if [ -s $DATA/subscription.json ]; then ok "config stored: $(subst nodes) nodes, source: $(subst source | grep . || echo url)"
else fail "no config stored. Settings » General: subscription URL (then Overview » Update subscription) or Config file"; fi
e="$(subst last_error)"; [ -n "$e" ] && warn "last subscription error: $e"
[ "$(u enabled)" = 1 ] && ok "start on boot: yes" || warn "start on boot: no (Overview » Enable & start)"
if /etc/init.d/nxsb running 2>/dev/null; then ok "service running (pid $(pidof nxsb 2>/dev/null | cut -d' ' -f1))"
else fail "service not running. Overview » Enable & start, then read the Log page"; fi
if [ -x $BIN ] && [ -s $DATA/subscription.json ]; then
	if /etc/init.d/nxsb check >/dev/null 2>&1; then ok "generated config passes the core's check"
	else fail "generated config rejected by the core: $(tail -1 $RUN/check.out 2>/dev/null | sed "s/$(printf '\033')\[[0-9;]*m//g" | cut -c1-160)"; fi
fi

# ---- api / dashboard ----
port="$(cat $RUN/api.port 2>/dev/null)"; port="${port:-$(u api_port)}"; port="${port:-9091}"
printf '\0\0\0\0\0' > $RUN/diag.req 2>/dev/null
sec="$(u api_secret)"
if [ -n "$(uclient-fetch -q -T 5 -O - --post-file=$RUN/diag.req --header='Content-Type: application/grpc-web+proto' ${sec:+--header="authorization: Bearer $sec"} http://127.0.0.1:$port/daemon.StartedService/GetVersion 2>/dev/null)" ]; then ok "core API answers on port $port"
elif /etc/init.d/nxsb running 2>/dev/null; then fail "core API not answering on port $port (a refusal looks the same: check the Dashboard secret in Settings » Advanced against the events below)"; fi
rm -f $RUN/diag.req
[ -s $RUN/groups.json ] && ok "selector groups mirrored ($(grep -o '"tag"' $RUN/groups.json | wc -l) groups)" || { /etc/init.d/nxsb running 2>/dev/null && warn "no groups snapshot yet (watcher not connected)"; }
if [ "$(u dashboard)" != 0 ]; then
	host="$(u dashboard_host)"; host="${host:-dash.nxsb.arpa}"; dip="$(u dashboard_ip)"; dip="${dip:-10.255.255.254}"
	r="$(lookup "$host" 127.0.0.1)"
	[ "$r" = "$dip" ] && ok "dashboard name $host -> $dip" || warn "dashboard name $host does not resolve to $dip on the router (got '${r:-nothing}')"
	if /etc/init.d/nxsb running 2>/dev/null; then
		ip addr show dev lo 2>/dev/null | grep -q " $dip/" && ok "dashboard address $dip on the router" || warn "dashboard address $dip missing on lo (see Log for the reason)"
		nft list table inet nxsb >/dev/null 2>&1 && ok "port-80 redirect for the dashboard in place" || warn "no port-80 redirect (nft): use http://<router-ip>:$port/dashboard/"
	fi
fi

# ---- DNS ----
dp="$(cat $RUN/dns.port 2>/dev/null)"; dp="${dp:-$(u dns_listen_port)}"; dp="${dp:-5335}"
if /etc/init.d/nxsb running 2>/dev/null; then
	a="$(lookup www.gstatic.com 127.0.0.1:$dp)"
	[ -n "$a" ] && ok "core DNS listener answers on 127.0.0.1#$dp (www.gstatic.com -> $a)" || fail "core DNS listener on 127.0.0.1#$dp does not answer"
fi
if [ "$(u hijack_lan_dns)" != 0 ]; then
	if ls /tmp/dnsmasq*.d/nxsb.conf >/dev/null 2>&1; then ok "dnsmasq sends LAN DNS to the core first"
	elif /etc/init.d/nxsb running 2>/dev/null; then
		if [ -z "$(pidof dnsmasq)" ]; then warn "dnsmasq is not running on this router: LAN DNS is not through the core (point your resolver at 127.0.0.1#$dp)"
		elif ! grep -Ls '^port=0' /var/etc/dnsmasq.conf.* 2>/dev/null | grep -q .; then warn "dnsmasq serves DHCP only (port=0): LAN DNS is not through the core"
		else fail "dnsmasq drop-in missing (LAN DNS not through the core): restart the service"; fi
	fi
	uci -q show dhcp | grep -q "dhcp_option.*'6," && warn "DHCP hands out a custom DNS server (dhcp_option 6 in Network » DHCP and DNS): devices bypass the router's DNS and the core"
else warn "LAN DNS through the core is OFF (Settings » LAN)"; fi
up="$(awk '/^nameserver/ && $2 != "127.0.0.1" && $2 != "::1" {print $2; exit}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)"
[ -n "$up" ] && ok "ISP resolver known for fallback: $up" || warn "no ISP resolver known (WAN down?) - LAN DNS has no fallback when the core is down"
lan="$(uci -q get network.lan.ipaddr | cut -d/ -f1)"
if [ -n "$lan" ]; then
	a="$(lookup www.gstatic.com "$lan")"
	case "$a" in 198.1[89].*) ok "LAN DNS answers (fake-IP mode)";; "") fail "LAN DNS on $lan does not answer";; *) ok "LAN DNS answers with real addresses ($a)";; esac
fi

# ---- connectivity ----
if uclient-fetch -q -T 8 -O /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
	/etc/init.d/nxsb running 2>/dev/null && ok "internet through the tunnel works (gstatic reachable)" || ok "internet works (service not running, direct)"
else fail "cannot reach the internet from the router (gstatic): WAN down, clock wrong, or the selected node is dead - try another node"; fi
sh="$(u sub_url | sed -n 's|^https\?://\([^/]*\).*|\1|p')"
if [ -n "$sh" ]; then
	o="$(uclient-fetch -O /dev/null -T 6 "https://$sh/" 2>&1)"; rc=$?
	if [ $rc = 0 ] || echo "$o" | grep -q "HTTP error"; then ok "panel host reachable ($sh)"; else warn "panel host $sh not reachable right now (subscription updates will fail): $(echo "$o" | tail -1 | cut -c1-80)"; fi
fi

# ---- router ----
if command -v nft >/dev/null 2>&1; then nft list chain inet fw4 forward 2>/dev/null | grep -q nxsb0 && ok "firewall accepts tunnel traffic (fw4 include loaded)" || fail "firewall include for the tunnel not loaded: run 'fw4 reload' or reinstall the package"
else warn "nft not found: firewall is not fw4, tunnel traffic may be blocked"; fi
mem="$(awk '/^MemAvailable/ {print int($2/1024)}' /proc/meminfo)"; [ "${mem:-0}" -ge 60 ] && ok "RAM available: ${mem} MB" || warn "RAM available: ${mem} MB (the core needs ~70 MB, expect crashes)"
fl="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"; [ -n "$fl" ] && { [ "$fl" -ge 20 ] && ok "flash free: ${fl} MB" || warn "flash free: ${fl} MB (core upgrades need ~90 MB)"; }
[ "$(date +%Y)" -ge 2024 ] 2>/dev/null && ok "clock set" || fail "clock not set (year $(date +%Y)): TLS fails until NTP syncs"
for o in passwall passwall2 homeproxy openclash shadowsocksr ssr-plus v2raya; do [ -x /etc/init.d/$o ] && /etc/init.d/$o running 2>/dev/null && warn "$o is running too: two tunnel apps fight over routes and DNS"; done
echo
echo "--- settings (link cut to its host, secret hidden) ---"
uci -q show nxsb | sed -e "s|\(sub_url='https\?://[^/']*\).*|\1/…'|" -e "s|\(api_secret=\).*|\1'(hidden)'|" -e "/dns6_saved/d" -e "/bbr_saved/d"
[ -s $DATA/sub.json ] && cat $DATA/sub.json
echo
echo "--- last events ---"; tail -n 30 $DATA/events.log 2>/dev/null
echo
echo "--- core warnings ---"; grep -E '^(PANIC|FATAL|ERROR|WARN) ' $RUN/core.log 2>/dev/null | tail -n 30 | sed "s/$(printf '\033')\[[0-9;]*m//g" | cut -c1-200
echo
for j in "core install:core:$RUN/core-install.log" "modules:deps:$RUN/deps.log" "subscription:sub:$RUN/sub.log"; do
	n="${j%%:*}"; r="${j#*:}"; st="${r%%:*}"; f="${r#*:}"
	[ -s "$f" ] || continue
	echo "--- $n (state: $(cat $RUN/$st.state 2>/dev/null || echo idle)) ---"; tail -n 12 "$f"; echo
done
echo "--- syslog (nxsb, procd, kernel) ---"; logread 2>/dev/null | grep -E "nxsb|Out of memory|Killed process" | tail -n 25 | cut -c1-200
echo
echo "--- network ---"; ip addr show nxsb0 2>/dev/null | grep -E "inet|mtu" | sed 's/^ *//'; ip route 2>/dev/null | grep -E "^default" | head -3
cat /tmp/dnsmasq*.d/nxsb.conf 2>/dev/null | grep -v '^#'; grep -hE '^(server|port|no-resolv|strict-order)' /var/etc/dnsmasq.conf.* 2>/dev/null | sort -u | head -8
exit 0
