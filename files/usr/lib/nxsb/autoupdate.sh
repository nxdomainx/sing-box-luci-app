#!/bin/sh
# nxsb: periodic subscription refresh (cron, hourly). Re-fetches when main.auto_update hours have passed;
# restarts the core only if the stored config actually changed and the service is running.
NOW="$(date +%s)"

# core channel (stable/beta): look upstream once a day, upgrade when it moved; pinned never moves on its own
CH="$(uci -q get nxsb.main.core_channel)"
if [ -n "$CH" ] && [ "$CH" != pinned ]; then
	STAMP=/etc/nxsb/core-check; LASTC="$(cat $STAMP 2>/dev/null)"; LASTC="${LASTC:-0}"
	if [ $((NOW - LASTC)) -ge 86400 ]; then
		mkdir -p /etc/nxsb; echo "$NOW" > $STAMP
		/usr/lib/nxsb/core.sh check-update >/dev/null 2>&1 || logger -t nxsb "core update check: $(tail -1 /var/run/nxsb/core-install.log 2>/dev/null)"
	fi
fi

# nothing to do while the service is off (the cron line stays across stop/start)
[ "$(uci -q get nxsb.main.enabled)" = 1 ] || exit 0
# subscription state lives in /etc/nxsb/sub.json (older builds: uci)
SS=/etc/nxsb/sub.json
_ss() { [ -s $SS ] && jsonfilter -i $SS -e "@.$1" 2>/dev/null || uci -q get nxsb.main.sub_$1; }
_ev() { mkdir -p /etc/nxsb; echo "$(date '+%F %T') $*" >> /etc/nxsb/events.log; logger -t nxsb "$*"; }
[ "$(_ss source)" = file ] && exit 0   # config came from an uploaded file: nothing to refresh
# a subscription job started from the page is still running: leave it alone (its pid is recorded by the page;
# find -mmin may be missing on tiny BusyBox builds, so the pid comes first)
if [ "$(cat /var/run/nxsb/sub.state 2>/dev/null)" = running ]; then
	P="$(cat /var/run/nxsb/sub.pid 2>/dev/null)"
	if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then exit 0; fi
	[ -n "$(find /var/run/nxsb/sub.state -mmin -20 2>/dev/null)" ] && exit 0
fi
H="$(uci -q get nxsb.main.auto_update)"; [ "${H:-0}" -gt 0 ] 2>/dev/null || exit 0
LAST="$(_ss last_update)"; LAST="${LAST:-0}"
[ $((NOW - LAST)) -ge $((H * 3600)) ] 2>/dev/null || exit 0
SUB=/etc/nxsb/subscription.json
OLD="$(sha256sum $SUB 2>/dev/null | awk '{print $1}')"
ucode /usr/lib/nxsb/subscribe.uc >/dev/null 2>&1 || { _ev "auto-update: fetch failed ($(tail -1 /var/run/nxsb/sub.log 2>/dev/null))"; exit 1; }
NEW="$(sha256sum $SUB 2>/dev/null | awk '{print $1}')"
if [ "$OLD" != "$NEW" ]; then
	# the running core keeps running until the new config is known to be good; otherwise the previous one comes back
	if /etc/init.d/nxsb check >/dev/null 2>&1; then
		_ev "auto-update: subscription changed"
		/etc/init.d/nxsb running && /etc/init.d/nxsb restart
	else
		_ev "auto-update: new subscription rejected by the core, kept the previous one: $(tail -1 /var/run/nxsb/check.out 2>/dev/null | sed "s/$(printf '\033')\[[0-9;]*m//g" | cut -c1-160)"
		[ -s $SUB.prev ] && mv -f $SUB.prev $SUB
		exit 1
	fi
else
	logger -t nxsb "auto-update: no change"
fi
