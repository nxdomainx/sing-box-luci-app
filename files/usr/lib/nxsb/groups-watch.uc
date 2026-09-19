#!/usr/bin/ucode
// nxsb: keeps a stream open on the core's api service and mirrors it to a file, so the page reads state from a
// file instead of starting the 70 MB core CLI. Runs as procd instances next to the core:
//   groups-watch.uc          SubscribeGroups -> /var/run/nxsb/groups.json (removed on any disconnect)
//   groups-watch.uc logs     SubscribeLog    -> /var/run/nxsb/core.log (last 500 lines, "LEVEL message")
// A refused stream (wrong secret, api service off) is an EMPTY reply, not an error frame: three empty replies in
// a row are reported once (syslog + service events) and the retry slows down until the stream delivers again.
import { popen, writefile, rename, unlink, open } from 'fs';
import { frame, fetch_cmd, fetch_reason, endpoint, decode_groups, pb_decode } from 'nxsb.grpc';

const RUN = '/var/run/nxsb';
const MODE = ARGV[0] == 'logs' ? 'logs' : 'groups';
const OUT = MODE == 'logs' ? `${RUN}/core.log` : `${RUN}/groups.json`;
const REQ = `${RUN}/${MODE}.req.bin`;
const ERR = `${RUN}/${MODE}.err`;
const LEVEL = [ 'PANIC', 'FATAL', 'ERROR', 'WARN', 'INFO', 'DEBUG', 'TRACE' ];
let lines = [], empties = 0, noted = false;

function shq(s) { return "'" + replace(`${s}`, "'", "'\\''") + "'"; }
function stamp() { let t = localtime(); return sprintf('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec); }
// syslog + the service events file the Log page and the diagnostics show
function note(m) {
	system(`logger -t nxsb ${shq(m)}`);
	let f = open('/etc/nxsb/events.log', 'a'); if (f) { f.write(`${stamp()} ${m}\n`); f.close(); }
}

function handle(m) {
	if (MODE == 'groups') {
		writefile(`${OUT}.tmp`, sprintf('%J', { at: time(), groups: decode_groups(m) }));
		rename(`${OUT}.tmp`, OUT);
		return;
	}
	for (let f in pb_decode(m)) {
		if (f.f == 2 && f.w == 0 && f.v) lines = [];                 // reset flag
		if (f.f != 1 || f.w != 2) continue;
		let lvl = 0, text = '';                                       // proto3 omits level 0 (PANIC) on the wire
		for (let x in pb_decode(f.v)) { if (x.f == 1 && x.w == 0) lvl = x.v; else if (x.f == 2 && x.w == 2) text = x.v; }
		push(lines, `${LEVEL[lvl] ?? lvl} ${replace(text, /\r?\n/g, ' ')}`);
	}
	if (length(lines) > 500) lines = slice(lines, -500);
	writefile(`${OUT}.tmp`, join('\n', lines) + '\n');
	rename(`${OUT}.tmp`, OUT);
}

unlink(OUT);                                                          // never serve last run's snapshot
writefile(REQ, frame(''));
while (true) {
	let p = popen(fetch_cmd(MODE == 'logs' ? 'SubscribeLog' : 'SubscribeGroups', REQ, 86400, ERR), 'r');
	let frames = 0, refused = null, rc = -1;
	if (p) {
		while (true) {
			let h = p.read(5);
			if (h == null || length(h) < 5) break;
			let flag = ord(h, 0), l = (ord(h, 1) << 24) | (ord(h, 2) << 16) | (ord(h, 3) << 8) | ord(h, 4);
			let m = l > 0 ? p.read(l) : '';
			if (l > 0 && (m == null || length(m) < l)) break;
			frames++;
			if (flag & 0x80) {
				let st = match(m, /grpc-status: *([0-9]+)/), ms = match(m, /grpc-message: *([^\r\n]*)/);
				if (st && st[1] != '0') refused = `status ${st[1]}${ms ? ': ' + ms[1] : ''}`;   // status 0 = a normal end of stream
				break;
			}
			handle(m);
		}
		rc = p.close();
	}
	if (MODE == 'groups') unlink(OUT);
	if (frames > 0 && refused == null) {
		if (noted) { note(`${MODE} stream to the core api is back`); noted = false; }
		empties = 0;
		system('sleep 2');                                            // the core went away: normal on restart
		continue;
	}
	empties++;
	// a refusal (rc 0, empty) is certain after 3 tries; "not reachable" gets 6 (a slow core start or a procd respawn)
	let limit = (refused || rc == 0) ? 3 : 6;
	if (empties == limit && !noted) {
		let why = refused ? `refused by the core api (${refused})` : (rc == 0 ? 'refused by the core api: wrong API secret? (Settings » Advanced » Dashboard secret must match a running core)' : fetch_reason(rc, ERR, endpoint().port));
		note(`${MODE} stream: ${why}; retrying every 20 s`);
		noted = true;
	}
	system(empties >= limit ? 'sleep 20' : 'sleep 2');
}
