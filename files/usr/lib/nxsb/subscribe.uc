#!/usr/bin/ucode
// nxsb: fetch the panel's sing-box configuration for this router (matched by our User-Agent) and store it verbatim.
// The generator overlays router-specific settings on top at start time.
//   ucode subscribe.uc            -> /var/run/nxsb/sub.log, sub.state ; /etc/nxsb/subscription.json
//   ucode subscribe.uc import F   same checks and store for a config file the user uploaded (source = file)
'use strict';

import { cursor } from 'uci';
import { popen, open, mkdir, writefile, readfile, rename, stat, unlink } from 'fs';

const RUN = '/etc/nxsb'; const STATE = '/var/run/nxsb';
const SUB = `${RUN}/subscription.json`;
const SUBSTATE = `${RUN}/sub.json`;        // source, last_update, last_error, nodes: state, not settings (never in uci)
const ERR = `${STATE}/sub.err`;
mkdir(RUN); mkdir(STATE);
const logf = open(`${STATE}/sub.log`, 'w');
function log(m) { if (logf) { logf.write(`${m}\n`); logf.flush(); } }
function state(s) { writefile(`${STATE}/sub.state`, s); }
function shq(s) { return "'" + replace(s, "'", "'\\''") + "'"; }
function substate() { let j; try { j = json(readfile(SUBSTATE)); } catch (e) { j = null; } return type(j) == 'object' ? j : {}; }
function save_substate(o) { writefile(`${SUBSTATE}.tmp`, sprintf('%J\n', { ...substate(), ...o })); rename(`${SUBSTATE}.tmp`, SUBSTATE); }
// last meaningful line of the downloader's stderr
function errline() { let last = ''; for (let l in split(readfile(ERR) ?? '', '\n')) { l = trim(l); if (l != '' && !match(l, /^(Downloading|Writing to|Download completed|  % Total|  % Received|Dload)/)) last = l; } return substr(last, 0, 200); }

const uci = cursor();
const main = uci.get_all('nxsb', 'main') || {};
const url = trim(main.sub_url ?? '');
const appver = trim(readfile('/usr/lib/nxsb/VERSION') ?? '0');
let corever = '';
{ let p = popen('/usr/bin/nxsb version 2>/dev/null', 'r'); if (p) { let l = p.read('line'); p.close(); let m = match(l ?? '', /version ([0-9.]+)/); if (m) corever = m[1]; } }
// the panel matches this UA to its router template (response rule "OpenWrt router (nxsb)")
const rel = (match(readfile('/etc/openwrt_release') ?? '', /DISTRIB_RELEASE='([^']*)'/) || [])[1] ?? '';
const arch = (match(readfile('/etc/openwrt_release') ?? '', /DISTRIB_ARCH='([^']*)'/) || [])[1] ?? '';
// no core yet: claim the newest pinned version so the panel picks the template that core will get
if (corever == '') { for (let l in split(readfile('/usr/lib/nxsb/core-versions') ?? '', '\n')) { let m = match(l, /^([0-9][0-9.]*) /); if (m) corever = m[1]; } }
const ua = `nxsb/${appver} (OpenWrt ${rel}; ${arch}; sing-box ${corever || '1.14'})`;

function fail(msg) { log(msg); save_substate({ last_error: msg }); state('failed'); exit(1); }

function run() {
const importFile = (ARGV[0] == 'import') ? (ARGV[1] ?? '') : '';
let body;
state('running');
if (importFile != '') {
	if (!match(importFile, /^\/tmp\/nxsb-sub-upload\.json$/)) fail('bad import path');
	let st = stat(importFile);                                   // size before reading: /tmp is RAM
	if (!st || !st.size) fail('the uploaded file is empty');
	if (st.size > 4 * 1024 * 1024) fail(`the uploaded file is too big for a sing-box config (${st.size} bytes, limit 4 MB)`);
	body = readfile(importFile);
	if (body == null || !length(body)) fail('the uploaded file could not be read');
	log(`importing ${length(body)} bytes from the uploaded file`);
} else {
	if (!match(url, /^https?:\/\//)) fail('no subscription URL configured');
	log(`fetching ${replace(url, /^(https?:\/\/[^\/?#]+).*/, '$1/…')} as ${ua}`);
	// the body is the config, the downloader's own messages go to a file: without -q uclient-fetch says
	// "HTTP error 404" / "Connection error"; with -q it says nothing at all
	let curl = system('command -v curl >/dev/null 2>&1') == 0;
	let cmd = curl
		? `curl -fsSL -S -m 60 --max-filesize 4194304 -A ${shq(ua)} ${shq(url)} 2>${shq(ERR)}`
		: `uclient-fetch -T 60 -U ${shq(ua)} -O - ${shq(url)} 2>${shq(ERR)}`;
	let p = popen(cmd, 'r'); body = p ? p.read('all') : null; let rc = p ? p.close() : -1;
	if (rc != 0 || body == null || !length(body)) {
		let e = errline();
		if (e == '') {
			let conn = 'connection failed (panel host unreachable, DNS, or the router has no internet)', tls = 'TLS error (clock not set? certificate?)', http = 'the panel answered with an HTTP error';
			e = curl ? ({ '6': conn, '7': conn, '28': 'timed out', '22': http, '35': tls, '60': tls }[`${rc}`] ?? `curl rc=${rc}`)
			         : ({ '4': conn, '5': tls, '8': http }[`${rc}`] ?? `rc=${rc}`);
		}
		fail(`download failed: ${e}`);
	}
	if (length(body) > 4 * 1024 * 1024) fail('response is too big for a sing-box config (over 4 MB)');
}
unlink(ERR);

let doc;
try { doc = json(body); } catch (e) {
	let head = replace(substr(body, 0, 60), /[^\x20-\x7e]/g, '.');
	fail(importFile != '' ? `the file is not JSON (starts with "${head}"): export a sing-box config (.json) and upload that`
	                      : `response is not JSON (starts with "${head}"): the panel did not serve a sing-box config for this User-Agent`);
}
if (type(doc) != 'object' || type(doc.outbounds) != 'array' || type(doc.route) != 'object')
	fail('JSON is not a sing-box configuration (needs outbounds[] and route{})');
let nodes = 0, groups = [];
for (let ob in doc.outbounds) {
	if (type(ob) != 'object') continue;
	if (ob.type == 'selector' || ob.type == 'urltest') push(groups, ob.tag);
	else if (ob.type != 'direct' && ob.type != 'block' && ob.type != 'dns') nodes++;
}
if (!nodes) fail('configuration has no proxy outbounds');

if (writefile(`${SUB}.new`, body) != length(body)) fail('could not write the subscription (flash full?)');
// keep the previous config: the hourly refresh restarts into the new one only if the core accepts it
if (stat(SUB)) rename(SUB, `${SUB}.prev`);
rename(`${SUB}.new`, SUB);
save_substate({ last_update: time(), last_error: '', nodes, source: importFile != '' ? 'file' : 'url' });
log(`stored ${length(body)} bytes${importFile != '' ? ' (uploaded file)' : ''}: ${nodes} nodes, groups: ${join(', ', groups)}`);
state('done');
}
try { run(); } catch (e) { fail(`internal error: ${e}`); }
