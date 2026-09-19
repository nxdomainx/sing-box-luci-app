#!/usr/bin/ucode
// nxsb: render the core configuration = the panel's stored router config + local overlay (idempotent).
// The panel owns routing policy (rules, rule-sets, DNS, selectors). This only adapts what a router needs.
'use strict';

import { cursor } from 'uci';
import { stderr, readfile } from 'fs';

const SUB = '/etc/nxsb/subscription.json';
const uci = cursor();
const main = uci.get_all('nxsb', 'main') || {};

function fail(msg) { stderr.write(`nxsb generate: ${msg}\n`); exit(1); }
function bool(v, d) { return v == null || v == '' ? d : (v == '1' || v == 'true' || v == 'on'); }
function str(v, d) { return (v == null || v == '') ? d : v; }
function list(v) { return v == null ? [] : (type(v) == 'array' ? v : [v]); }
function nonempty(a) { return filter(a, x => x != null && x != ''); }
// a panel field of the wrong shape ("inbounds": {}) must not silently become nothing: filter() on a non-array
// returns null and push() on null is a no-op, so normalise the shape first
function arr(v) { return type(v) == 'array' ? v : []; }
function obj(v) { return type(v) == 'object' ? v : {}; }

let raw = readfile(SUB);
if (!raw) fail('no subscription stored: set the URL in Settings and press Update');
let cfg;
try { cfg = json(raw); } catch (e) { fail('stored subscription is not valid JSON; update it again'); }
if (type(cfg) != 'object' || type(cfg.outbounds) != 'array') fail('stored subscription is not a sing-box config');

// ---- log -> syslog via procd
// log level: the panel's unless overridden in Settings; timestamps off (syslog adds them)
cfg.log = obj(cfg.log);
cfg.log.disabled = false;
cfg.log.timestamp = false;
delete cfg.log.output;
if (str(main.log_level, '') != '') cfg.log.level = main.log_level;
else if (!cfg.log.level) cfg.log.level = 'info';

// ---- tun inbound: keep the panel's addresses/mtu, adapt to a router
let tun = null;
cfg.inbounds = filter(arr(cfg.inbounds), i => type(i) == 'object' && i.type != 'direct');
for (let i in cfg.inbounds) if (i.type == 'tun') { tun = i; break; }
if (!tun) { tun = { type: 'tun', tag: 'tun-in', address: ['172.16.0.1/30'], auto_route: true }; push(cfg.inbounds, tun); }
cfg.inbounds = filter(cfg.inbounds, i => i.type != 'tun' || i === tun);   // one TUN on a router, never two
tun.interface_name = 'nxsb0';
tun.auto_route = true;
tun.strict_route = false;              // a router forwards LAN traffic; strict mode breaks that
tun.stack = str(main.tun_stack, 'system');
tun.mtu = str(main.tun_mtu, '') != '' ? +main.tun_mtu : 1500;
delete tun.auto_redirect;
if (bool(main.auto_redirect, false)) tun.auto_redirect = true;

// ---- DNS listener for dnsmasq (LAN DNS is answered by the core through hijack-dns).
//      The port comes from Settings (single source of truth); the init script resolves collisions and
//      exports NXSB_DNS_PORT, so the dnsmasq drop-in and this inbound always agree.
const dns_port = +str(getenv('NXSB_DNS_PORT'), str(main.dns_listen_port, '5335'));
if (bool(main.hijack_lan_dns, true))
	push(cfg.inbounds, { type: 'direct', tag: 'dns-in', listen: '127.0.0.1', listen_port: dns_port, network: 'udp', override_address: '1.1.1.1', override_port: 53 });

// ---- "local" DNS on OpenWrt is dnsmasq itself -> loop. Use the WAN-provided resolver instead.
function upstream_resolver() {
	for (let f in ['/tmp/resolv.conf.d/resolv.conf.auto', '/tmp/resolv.conf.auto']) {
		let s = readfile(f); if (!s) continue;
		// IPv4 first, then IPv6 (IPv6-only WAN): same order the dnsmasq fallback uses
		for (let re in [ /^nameserver[ \t]+([0-9.]+)/, /^nameserver[ \t]+([0-9a-fA-F:]+)/ ])
			for (let line in split(s, '\n')) { let m = match(line, re); if (m && m[1] != '127.0.0.1' && m[1] != '::1') return m[1]; }
	}
	return null;
}
let direct_spec = str(main.dns_direct, 'auto');
let direct_srv = direct_spec == 'auto' ? (upstream_resolver() || '8.8.8.8') : direct_spec;
cfg.dns = obj(cfg.dns);
cfg.dns.servers = filter(arr(cfg.dns.servers), x => type(x) == 'object');
cfg.dns.rules = filter(arr(cfg.dns.rules), x => type(x) == 'object');
cfg.outbounds = filter(arr(cfg.outbounds), x => type(x) == 'object' && x.tag != null);
if (cfg.endpoints != null) cfg.endpoints = filter(arr(cfg.endpoints), x => type(x) == 'object' && x.tag != null);
cfg.route = obj(cfg.route);
cfg.route.rules = filter(arr(cfg.route.rules), x => type(x) == 'object');
let direct_tags = {};
for (let ob in cfg.outbounds) if (ob.type == 'direct') direct_tags[ob.tag] = true;
// the direct outbound the bypass rule points at: the panel's own, or one we add under a tag nobody uses
let direct_tag = keys(direct_tags)[0];
if (!direct_tag) {
	direct_tag = 'direct';
	while (length(filter(cfg.outbounds, o => o.tag == direct_tag)) || length(filter(arr(cfg.endpoints), o => o.tag == direct_tag))) direct_tag = 'nxsb-' + direct_tag;
	push(cfg.outbounds, { type: 'direct', tag: direct_tag }); direct_tags[direct_tag] = true;
}
// Settings » LAN » Direct resolver: plain UDP to an IP (tls/https would need a bootstrap resolver of their own)
function direct_server(spec) { return { type: 'udp', server: spec }; }
if (!length(cfg.dns.servers)) push(cfg.dns.servers, { tag: 'dns_direct', ...direct_server(direct_srv) });
for (let s in cfg.dns.servers) {
	if (s.type == 'local') { let d = direct_server(direct_srv); s.type = d.type; s.server = d.server; if (d.path) s.path = d.path; delete s.detour; delete s.prefer_go; }
	// 1.14 refuses a DNS detour to a bare direct outbound ("makes no sense"); no detour = direct anyway
	if (s.detour != null && direct_tags[s.detour]) delete s.detour;
}

// ---- with an IPv4-only strategy the core gives AAAA no answer at all; dnsmasq would then retry the ISP resolver
//      (which is exactly where the poison lives). Answer AAAA with an empty NOERROR instead.
if ((cfg.dns.strategy ?? '') == 'ipv4_only' && !length(filter(cfg.dns.rules, r => r.action == 'predefined' && index(list(r.query_type), 'AAAA') >= 0)))
	unshift(cfg.dns.rules, { query_type: ['AAAA'], action: 'predefined', rcode: 'NOERROR' });

// ---- LAN queries (dns-in): real answers, no fake-IP. Devices running their own sing-box/fake-IP client would collide
//      with the router's fake range (Cloudflare 1034 etc.). To keep resolver and traffic leaving from the same node, the
//      panel's routing is mirrored on the DNS side: for each route rule "domains -> outbound" (group or single node,
//      anything but direct), a copy of the final resolver detoured through that outbound answers those domains. Everything else uses the panel's final resolver.
if (bool(main.hijack_lan_dns, true) && !bool(main.lan_fakeip, false)) {
	// no dns.final in the template = sing-box uses the first server as the default; mirror that
	// fake-IP servers are identified by TYPE, not by name
	let fake = {};
	for (let sv in cfg.dns.servers) if (sv.type == 'fakeip') fake[sv.tag] = true;
	// LAN answers must be real addresses: the panel's final resolver, or the first real one when that is fake-IP
	let fin = cfg.dns.final;
	if (!fin || fake[fin]) {
		fin = null;
		// prefer a resolver that goes through the tunnel (detour to a non-direct outbound) over the bare direct one
		for (let sv in cfg.dns.servers) if (!fake[sv.tag] && sv.detour && !direct_tags[sv.detour]) { fin = sv.tag; break; }
		if (!fin) for (let sv in cfg.dns.servers) if (!fake[sv.tag]) { fin = sv.tag; break; }
	}
	let base = null;
	for (let sv in cfg.dns.servers) if (sv.tag == fin) base = sv;
	let rules = cfg.dns.rules;
	// any outbound or endpoint can carry a resolver: groups or single nodes; not direct (real resolver already) nor block-like
	let groups = {};
	for (let ob in cfg.outbounds) if (index(['direct', 'block', 'dns'], ob.type) < 0) groups[ob.tag] = true;
	for (let ep in arr(cfg.endpoints)) groups[ep.tag] = true;
	let added = [];
	if (base) {
		const DOMAIN_KEYS = ['rule_set', 'domain', 'domain_suffix', 'domain_keyword', 'domain_regex'];
		for (let r in (cfg.route.rules || [])) {
			let g = r.outbound;
			if (!g || !groups[g] || g == base.detour) continue;
			let m = {};
			for (let k in DOMAIN_KEYS) if (r[k] != null) m[k] = r[k];
			if (!length(keys(m))) continue;
			let tag = `${fin}@${g}`;
			if (!length(filter(cfg.dns.servers, sv => sv.tag == tag))) {
				let clone = { ...base, tag, detour: g };
				push(cfg.dns.servers, clone);
			}
			push(added, { inbound: ['dns-in'], ...m, server: tag });
		}
	}
	if (fin) push(added, { inbound: ['dns-in'], server: fin });
	// drop any earlier copies of our rules, then insert before the fake-IP rule
	rules = filter(rules, r => !(index(list(r.inbound), 'dns-in') >= 0 && r.action == null));
	let at = length(rules);
	for (let i = 0; i < length(rules); i++) if (rules[i].server && fake[rules[i].server]) { at = i; break; }
	splice(rules, at, 0, ...added);
	cfg.dns.rules = rules;
}

// ---- route: bypass devices (source IPs) go direct, right after the DNS hijack rule
cfg.route.auto_detect_interface = true;
// queries from dnsmasq arrive on dns-in; the panel's sniff rule only covers tun-in, so hijack them explicitly
if (bool(main.hijack_lan_dns, true)) {
	let has = length(filter(cfg.route.rules, r => r.action == 'hijack-dns' && index(list(r.inbound), 'dns-in') >= 0)) > 0;
	if (!has) unshift(cfg.route.rules, { inbound: ['dns-in'], action: 'hijack-dns' });
} else {
	cfg.route.rules = filter(cfg.route.rules, r => !(r.action == 'hijack-dns' && index(list(r.inbound), 'dns-in') >= 0));
}
let bypass = nonempty(list(main.bypass_src));
if (length(bypass)) {
	let at = 0;
	for (let i = 0; i < length(cfg.route.rules); i++) if (cfg.route.rules[i].action == 'hijack-dns') { at = i + 1; break; }
	splice(cfg.route.rules, at, 0, { source_ip_cidr: bypass, outbound: direct_tag });
}

// ---- api service: node selection on the page and the log mirror always need it (loopback only when the
//      dashboard is off); the bundled sing-box-dashboard is served at http://<router>:<api_port>/dashboard/
cfg.services = filter(arr(cfg.services), x => type(x) == 'object' && x.type != 'api');
let dash = bool(main.dashboard, true);
push(cfg.services, {
	type: 'api', tag: 'api',
	listen: dash ? '0.0.0.0' : '127.0.0.1', listen_port: +str(getenv('NXSB_API_PORT'), str(main.api_port, '9091')),
	secret: replace(str(getenv('NXSB_API_SECRET'), str(main.api_secret, '')), /[\r\n]/g, ''),
	dashboard: dash ? { enabled: true, path: '/usr/share/nxsb/dashboard' } : { enabled: false },
});

// ---- experimental: cache on flash (selections, fake-ip, rule-set cache survive restarts)
cfg.experimental = obj(cfg.experimental);
delete cfg.experimental.clash_api;   // the page and the dashboard both use the api service
cfg.experimental.cache_file = obj(cfg.experimental.cache_file);
cfg.experimental.cache_file.enabled = true;
cfg.experimental.cache_file.path = '/etc/nxsb/cache.db';

printf('%.J\n', cfg);
