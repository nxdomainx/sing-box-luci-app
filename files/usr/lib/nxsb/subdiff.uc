#!/usr/bin/ucode
// nxsb: decide whether a freshly fetched subscription is worth restarting the core for.
//   ucode subdiff.uc <applied.json> <new.json>   -> prints "same" | "defer <why>" | "restart <why>"
//
// The panel re-renders the config on every request, so the raw bytes differ almost every time without
// anything meaningful having changed. Two sources of that noise:
//   * ordering    - outbounds[] and the selector/urltest member lists come back in a different order.
//   * the counter - the usage node's tag carries the traffic and days left ("4.8 GB | 11 ⏳"), so it is
//                   renamed as the account is used, in the outbound and in every group that lists it.
// Both are cosmetic. A node is therefore identified by what it dials (everything but its tag), never by
// its name, and every tag reference in the document is rewritten to that identity before comparing.
//
// What earns a restart: the outbound currently selected in some group is gone or now dials somewhere else,
// or anything outside the outbound list moved (route rules, DNS, inbounds). Everything else - nodes added,
// removed or changed that nobody is on, a group's "default" - is stored and picked up the next time the
// core restarts for its own reasons. A selector's default only decides a cold start; the live choice comes
// back from cache.db, so it is not worth an interruption.
'use strict';

import { readfile } from 'fs';

// overridable so the decision can be exercised without a running core
const GROUPS = getenv('NXSB_GROUPS') ?? '/var/run/nxsb/groups.json';

function arr(v) { return type(v) == 'array' ? v : []; }
function isgroup(o) { return o.type == 'selector' || o.type == 'urltest'; }

// stable text for any value: object keys sorted, so key order never shows up as a difference
function canon(v) {
	let t = type(v);
	if (t == 'object') {
		let parts = [];
		for (let k in sort(keys(v))) push(parts, sprintf('%J', k) + ':' + canon(v[k]));
		return '{' + join(',', parts) + '}';
	}
	if (t == 'array') {
		let parts = [];
		for (let e in v) push(parts, canon(e));
		return '[' + join(',', parts) + ']';
	}
	return sprintf('%J', v);
}

// tag -> what that node actually dials (its definition with the name taken out)
function node_ids(cfg) {
	let m = {};
	for (let o in arr(cfg.outbounds)) {
		if (type(o) != 'object' || o.tag == null || isgroup(o)) continue;
		let c = {};
		for (let k in o) if (k != 'tag') c[k] = o[k];
		m[o.tag] = canon(c);
	}
	return m;
}

// rewrite every reference to a node's tag (its own tag field, group member lists, route rules) to that
// node's identity, so renaming the counter node is invisible. Group tags are stable and stay as they are.
function subst(v, m) {
	let t = type(v);
	if (t == 'string') return (m[v] != null) ? '#' + m[v] : v;
	if (t == 'array') {
		let o = [];
		for (let e in v) push(o, subst(e, m));
		return o;
	}
	if (t == 'object') {
		let o = {};
		for (let k in v) o[k] = subst(v[k], m);
		return o;
	}
	return v;
}

// the outbound list, order removed: member lists sorted, the list itself sorted, "default" dropped
function outbound_view(cfg) {
	let m = node_ids(cfg), out = [];
	for (let o in arr(cfg.outbounds)) {
		if (type(o) != 'object' || o.tag == null) continue;
		let c = subst(o, m);
		if (isgroup(o)) { delete c.default; c.outbounds = sort(arr(c.outbounds)); }
		push(out, canon(c));
	}
	return join('\n', sort(out));
}

// everything the panel sends that is not the outbound list: routing policy, DNS, inbounds, experimental
function rest_view(cfg) {
	let m = node_ids(cfg), o = {};
	for (let k in cfg) if (k != 'outbounds') o[k] = cfg[k];
	return canon(subst(o, m));
}

// Tags the core is actually on right now: the pick of every selector, followed through nested groups to a
// real node. urltest groups are left out - their pick is latency, not a choice, it drifts on its own, and
// their members are interchangeable by design: the running core will move off a bad one without our help.
function selected() {
	let g;
	try { g = json(readfile(GROUPS)); } catch (e) { return null; }
	if (type(g) != 'object' || type(g.groups) != 'array') return null;
	let bytag = {}, out = {};
	for (let x in g.groups) if (type(x) == 'object' && x.tag != null) bytag[x.tag] = x;
	for (let x in g.groups) {
		if (type(x) != 'object' || x.type == 'urltest') continue;
		let cur = x.now, hops = 0;
		while (cur != null && bytag[cur] != null && hops++ < 8) {
			if (bytag[cur].type == 'urltest') { cur = null; break; }   // the chain ends in a latency pick
			cur = bytag[cur].now;
		}
		if (cur != null && bytag[cur] == null) out[cur] = true;
	}
	return out;
}

function load(p) {
	let raw = readfile(p);
	if (!raw) return null;
	let d;
	try { d = json(raw); } catch (e) { return null; }
	return (type(d) == 'object' && type(d.outbounds) == 'array') ? d : null;
}

const old = load(ARGV[0]), new_ = load(ARGV[1]);
// no usable baseline (first run, or the applied copy was lost): treat it as new and let the caller apply it
if (!old || !new_) { print("restart no baseline to compare against\n"); exit(0); }

const ob_changed = outbound_view(old) != outbound_view(new_);
const rest_changed = rest_view(old) != rest_view(new_);

if (!ob_changed && !rest_changed) { print("same\n"); exit(0); }
if (rest_changed) { print("restart routing or DNS policy changed\n"); exit(0); }

// outbounds moved: does it reach anything we are on?
const sel = selected();
// the core is down or the mirror is not up yet: we cannot tell what is in use, so do not gamble
if (sel == null) { print("restart nodes changed, selection unknown\n"); exit(0); }

const oldm = node_ids(old), newm = node_ids(new_);
let live = {};
for (let t in newm) live[newm[t]] = true;
for (let tag in sel) {
	let id = oldm[tag];
	if (id == null) continue;                 // selected thing is not a plain node in the applied config
	if (!live[id]) { print(`restart the selected node "${tag}" is gone or dials somewhere else now\n`); exit(0); }
}
print("defer nodes changed, none of them in use\n");
