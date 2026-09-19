// nxsb: minimal gRPC-Web client for the core's api service (daemon.StartedService), no CLI process.
// Transport: uclient-fetch POST (stock OpenWrt), framing: 5-byte header (flag, u32 BE length) per message,
// flag 0x80 = trailers. Protobuf: only what the page needs (strings + varints, wire types 0/2).
// A refusal (wrong secret, unknown group/outbound) comes back as an EMPTY body: the status travels in HTTP
// headers, which uclient-fetch does not show. So "empty reply with exit code 0" means refused.
import { popen, writefile, unlink, readfile } from 'fs';
import { cursor } from 'uci';

const RUN = '/var/run/nxsb';

function shq(s) { return "'" + replace(`${s}`, "'", "'\\''") + "'"; }
function varint(n) { let s = ''; while (n >= 0x80) { s += chr((n & 0x7f) | 0x80); n = n >> 7; } return s + chr(n); }
function pb_str(field, s) { return chr((field << 3) | 2) + varint(length(s)) + s; }
// varint at offset i -> [value, next offset]
function rd_varint(buf, i, n) {
	let v = 0, shift = 0;
	while (i < n) {
		let b = ord(buf, i); i++;
		v = v | ((b & 0x7f) << shift); shift += 7;
		if (!(b & 0x80)) break;
	}
	return [ v, i ];
}
function pb_decode(buf) {
	let out = [], i = 0, n = length(buf);
	while (i < n) {
		let r = rd_varint(buf, i, n); let key = r[0]; i = r[1];
		let f = key >> 3, w = key & 7, v = null;
		if (w == 0) { r = rd_varint(buf, i, n); v = r[0]; i = r[1]; }
		else if (w == 2) { r = rd_varint(buf, i, n); let l = r[0]; i = r[1]; v = substr(buf, i, l); i += l; }
		else if (w == 1) i += 8;
		else if (w == 5) i += 4;
		else break;
		push(out, { f, w, v });
	}
	return out;
}
function frame(msg) { let l = length(msg); return chr(0) + chr((l >> 24) & 0xff) + chr((l >> 16) & 0xff) + chr((l >> 8) & 0xff) + chr(l & 0xff) + msg; }

function endpoint() {
	let u = cursor();
	let port = trim(readfile(`${RUN}/api.port`) ?? '');
	if (!match(port, /^[0-9]{1,5}$/)) port = u.get('nxsb', 'main', 'api_port') ?? '';
	if (!match(port, /^[0-9]{1,5}$/)) port = '9091';
	// CR/LF would break the header line; the settings page refuses them too
	let secret = replace(u.get('nxsb', 'main', 'api_secret') ?? '', /[\r\n]/g, '');
	return { url: `http://127.0.0.1:${port}/daemon.StartedService/`, secret, port };
}
// errfile: where uclient-fetch's own messages go (HTTP error N, Connection error); without it they are dropped
function fetch_cmd(method, bodyfile, timeout, errfile) {
	let ep = endpoint();
	let hdr = `--header='Content-Type: application/grpc-web+proto'` + (ep.secret != '' ? ` --header=${shq('authorization: Bearer ' + ep.secret)}` : '');
	return `uclient-fetch ${errfile ? '' : '-q '}-T ${timeout} -O - --post-file=${shq(bodyfile)} ${hdr} ${shq(ep.url + method)} 2>${errfile ? shq(errfile) : '/dev/null'}`;
}
// last meaningful line of uclient-fetch's stderr
function fetch_err(errfile) {
	let last = '';
	for (let l in split(readfile(errfile) ?? '', '\n')) { l = trim(l); if (l != '' && !match(l, /^(Downloading|Writing to|Download completed)/)) last = l; }
	return last;
}
// plain words for a failed uclient-fetch exit code
function fetch_reason(rc, errfile, port) {
	let e = errfile ? fetch_err(errfile) : '';
	if (rc == 4) return `api service not reachable on 127.0.0.1:${port} (core restarting or not running?)`;
	if (rc == 8) return `api service answered with an error${e != '' ? ': ' + e : ''}`;
	return `request to the api service failed (uclient-fetch rc=${rc}${e != '' ? ': ' + e : ''})`;
}

// unary call: returns { ok, status, message, msgs: [raw message bytes] }
function call(method, body) {
	let ep = endpoint();
	let f = `${RUN}/req.${time()}.${substr(sprintf('%f', time() / 7), -4)}.bin`;
	writefile(f, frame(body ?? ''));
	let p = popen(fetch_cmd(method, f, 5, `${f}.err`), 'r');
	let out = p ? p.read('all') : null; let rc = p ? p.close() : -1;
	let r = { ok: false, status: -1, message: '', msgs: [] };
	if (!p) r.message = 'could not start uclient-fetch';
	else if (rc != 0) r.message = fetch_reason(rc, `${f}.err`, ep.port);
	else if (out == null || length(out) == 0) r.message = 'refused by the core: wrong API secret, or the group/outbound does not exist';
	unlink(f); unlink(`${f}.err`);
	if (r.message != '') return r;
	let i = 0, frames = 0;
	while (i + 5 <= length(out)) {
		let flag = ord(out, i), l = (ord(out, i + 1) << 24) | (ord(out, i + 2) << 16) | (ord(out, i + 3) << 8) | ord(out, i + 4);
		if (i + 5 + l > length(out)) break;             // truncated frame: not a message
		let m = substr(out, i + 5, l); i += 5 + l; frames++;
		if (flag & 0x80) {
			let st = match(m, /grpc-status: *([0-9]+)/); if (st) r.status = +st[1];
			let ms = match(m, /grpc-message: *([^\r\n]*)/); if (ms) r.message = ms[1];
		} else push(r.msgs, m);
	}
	if (!frames) { r.message = `unreadable reply from the api service on 127.0.0.1:${ep.port} (${length(out)} bytes)`; return r; }
	if (r.status == -1 && length(r.msgs)) r.status = 0;
	r.ok = r.status == 0;
	if (!r.ok && r.message == '') r.message = `api error ${r.status}`;
	return r;
}

// Groups message -> plain objects (same shape the page always used)
function decode_groups(msg) {
	let out = [];
	for (let g in pb_decode(msg)) {
		if (g.f != 1 || g.w != 2) continue;
		let grp = { tag: '', type: '', now: null, all: [], delay: null, items: {} };
		for (let x in pb_decode(g.v)) {
			if (x.f == 1) grp.tag = x.v; else if (x.f == 2) grp.type = x.v; else if (x.f == 4) grp.now = x.v == '' ? null : x.v;
			else if (x.f == 6) {
				let it = { tag: '', delay: 0 };
				for (let y in pb_decode(x.v)) { if (y.f == 1) it.tag = y.v; else if (y.f == 4) it.delay = y.v; }
				push(grp.all, it.tag); grp.items[it.tag] = it.delay > 0 ? it.delay : null;
			}
		}
		grp.delay = grp.now ? (grp.items[grp.now] ?? null) : null;
		push(out, grp);
	}
	return out;
}

export { varint, pb_str, pb_decode, frame, endpoint, fetch_cmd, fetch_reason, call, decode_groups };
