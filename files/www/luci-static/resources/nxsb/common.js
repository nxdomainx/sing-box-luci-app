'use strict';
'require baseclass';
'require rpc';
'require ui';

// every call rejects on a ubus error (permission denied, unknown method) instead of resolving to a bare number
var callCoreInst   = rpc.declare({ object: 'luci.nxsb', method: 'core_install', params: [ 'version', 'sha256' ], reject: true });
var callCoreStatus = rpc.declare({ object: 'luci.nxsb', method: 'core_status', reject: true });
var callCoreGuide  = rpc.declare({ object: 'luci.nxsb', method: 'core_guide', reject: true });
var callCoreImport = rpc.declare({ object: 'luci.nxsb', method: 'core_import', params: [ 'path' ], reject: true });
var callDepsInst   = rpc.declare({ object: 'luci.nxsb', method: 'deps_install', params: [ 'what' ], reject: true });
var callDepsStatus = rpc.declare({ object: 'luci.nxsb', method: 'deps_status', reject: true });
var callDepsGuide  = rpc.declare({ object: 'luci.nxsb', method: 'deps_guide', params: [ 'what' ], reject: true });
var callDepsImport = rpc.declare({ object: 'luci.nxsb', method: 'deps_import', params: [ 'path' ], reject: true });
var callBbrApply   = rpc.declare({ object: 'luci.nxsb', method: 'bbr_apply', reject: true });
var callSubImport  = rpc.declare({ object: 'luci.nxsb', method: 'sub_import', params: [ 'path' ], reject: true });
var callSubStatus  = rpc.declare({ object: 'luci.nxsb', method: 'sub_status', reject: true });
var callDiag       = rpc.declare({ object: 'luci.nxsb', method: 'diag', reject: true });
var callDiagStatus = rpc.declare({ object: 'luci.nxsb', method: 'diag_status', reject: true });
var callReset      = rpc.declare({ object: 'luci.nxsb', method: 'reset_settings', params: [ 'full' ], reject: true });
var callDestroy    = rpc.declare({ object: 'luci.nxsb', method: 'destroy_workdir', reject: true });

// the two kernel modules the app can fetch or take as an upload; both come from the router's own kmods feed
var KMOD = { tun: { pkg: 'kmod-tun', name: _('the TUN module') }, bbr: { pkg: 'kmod-tcp-bbr', name: _('the BBR module') } };
// a failure that the offline guide can help with (everything else has its own reason to show)
var NETWORK_FAIL = /download failed|opkg update failed|unreachable|no internet|not reachable|could not look up|Connection|timed out/i;

return baseclass.extend({
	badge: function(ok, text) {
		return E('span', { 'style': 'background:' + (ok ? '#2e7d32' : '#b71c1c') + ';color:#fff;padding:2px 8px;border-radius:3px;font-weight:bold' }, [ text ]);
	},

	// read-only LuCI login: every action button stays visible but off, with the reason
	readonly: function() { return !L.hasViewPermission(); },
	roNote: function() { return this.readonly() ? E('p', { 'style': 'color:#b71c1c' }, _('This login is read-only: actions are disabled.')) : ''; },

	// what a rejected rpc call means to the person in front of the page
	errText: function(e) {
		var m = (e && e.message) || String(e);
		if (/ubus code 6|Permission denied|Access denied/i.test(m)) return _('Not allowed for this login. Read-only account, or log out and back in after upgrading the app.');
		if (/ubus code (2|3|4)|Invalid (command|argument)|Method not found|Object not found|error -32000/i.test(m)) return _('The router does not know this call yet. Reload the page; if it stays, run "/etc/init.d/rpcd reload" or reboot.');
		if (/XHR request timed out|timeout/i.test(m)) return _('The router did not answer in time (busy?). Try again in a moment.');
		return m;
	},
	fail: function(e) { ui.addNotification(null, E('p', {}, [ this.errText(e) ]), 'warning'); },
	warn: function(text) { ui.addNotification(null, E('p', {}, [ text ]), 'warning'); },
	info: function(text) { if (ui.addTimeLimitedNotification) ui.addTimeLimitedNotification(null, E('p', {}, [ text ]), 5000, 'info'); else ui.addNotification(null, E('p', {}, [ text ]), 'info'); },
	// the reason from a job log: the last line that reads like a failure, else the last line (a hint often follows the reason)
	lastLine: function(log) {
		var l = (log || []).filter(function(x) { return x && x.trim(); }).map(function(x) { return x.replace(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d /, ''); });
		if (!l.length) return '';
		for (var i = l.length - 1; i >= 0; i--) if (/failed|error|warning|cannot|could not|wrong|not an? |does not|missing|refused|mismatch|rejects|no such/i.test(l[i])) return l[i];
		return l[l.length - 1];
	},

	// progress modal in plain words; the raw script log stays behind a collapsed "Details".
	// onDone(state, lastLine): state is 'done', 'failed' or 'stuck' (still running after 20 minutes); lastLine is the
	// script's reason on failure
	taskModal: function(title, waitMsg, pollFn, onDone) {
		var self = this;
		var msg = E('p', {}, waitMsg);
		var pre = E('pre', { 'style': 'max-height:200px;overflow:auto;font-size:11px' }, '…');
		var btn = E('button', { 'class': 'btn', 'disabled': '' }, _('Please wait…'));
		ui.showModal(title, [ msg, E('details', {}, [ E('summary', { 'style': 'cursor:pointer;opacity:.7' }, _('Details')), pre ]), E('div', { 'class': 'right' }, [ btn ]) ]);
		var started = Date.now(), misses = 0, lastLog = [], finished = false;
		var finish = function(state, text) {
			if (finished) return;                      // a poll still in flight when the first one ended must not fire twice
			finished = true;
			window.clearInterval(timer);
			var last = self.lastLine(lastLog);
			msg.textContent = text || (state == 'done' ? _('Done.') : (last ? _('It did not work: %s').format(last) : _('It did not work. See the Log page.')));
			btn.textContent = _('OK'); btn.removeAttribute('disabled');
			btn.addEventListener('click', function() { ui.hideModal(); if (onDone) onDone(state, last); });
		};
		var timer = window.setInterval(function() {
			if (Date.now() - started > 20 * 60 * 1000) { finish('stuck', _('Still running after 20 minutes. Close this and check the Log page later.')); return; }
			pollFn().then(function(r) {
				if (finished) return;
				misses = 0;
				lastLog = r.log || [];
				pre.textContent = lastLog.join('\n') || '…';
				pre.scrollTop = pre.scrollHeight;
				if (r.state == 'done' || r.state == 'failed') finish(r.state);
			}).catch(function(e) {
				if (finished) return;
				// one missed poll while opkg hogs the CPU is not a failure; three in a row is
				if (++misses >= 3) { lastLog = lastLog.concat([ self.errText(e) ]); pre.textContent = lastLog.join('\n'); finish('failed'); }
			});
		}, 1000);
	},

	// "no internet" fallback: two steps, upload button right there
	handGuide: function(what, g, uploadFn, failed, reason) {
		var self = this;
		if (g && g.error) return this.warn(g.error);
		ui.showModal(failed ? _('Download failed') : _('Install %s by hand').format(what), [
			failed ? E('p', {}, [ reason ? _('The router could not download it: %s').format(reason) : _('The router could not download it.'), ' ', _('No internet on the router, or the site is blocked here. Do it from your PC instead:') ]) : '',
			E('ol', {}, [
				E('li', {}, g.url ? [ _('On your PC download '), E('a', { 'href': g.url, 'target': '_blank' }, [ g.file || g.url ]), '.' ]
				                  : [ _('On your PC open '), E('a', { 'href': (g.feed || '') + '/', 'target': '_blank' }, _('this folder')), _(', open the subfolder starting with %s and download %s.').format(g.kernel || '?', g.file || '?') ]),
				E('li', {}, _('Click "Upload from PC" and pick that file. No need to unzip.'))
			]),
			g.note ? E('p', {}, [ g.note ]) : '',
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': function() { ui.hideModal(); uploadFn.call(self); } }, _('Upload from PC'))
			])
		]);
	},
	coreGuide: function(failed, reason) { var self = this; return callCoreGuide().then(function(g) { self.handGuide(_('the core'), g, self.uploadCore, failed, reason); }).catch(function(e) { self.fail(e); }); },
	kmodGuide: function(what, failed, reason) { var self = this; what = KMOD[what] ? what : 'tun'; return callDepsGuide(what).then(function(g) { self.handGuide(KMOD[what].pkg, g, function() { self.uploadKmod(what); }, failed, reason); }).catch(function(e) { self.fail(e); }); },

	// a failed download: the offline guide when the network is the reason, the reason itself otherwise
	afterFail: function(reason, guideFn) { if (!reason || NETWORK_FAIL.test(reason)) guideFn(reason); else this.warn(reason); },

	// a job of this kind is already running (the install-time job queued by postinst, or another tab): show it
	// instead of refusing; then(state) runs when it ends, default = reload
	busy: function(r, statusFn, title, then) {
		if (!(r && r.error && /already running/.test(r.error))) return false;
		this.taskModal(title, _('A job of this kind is already running (started at install time, or from another page). Waiting for it.'), statusFn,
			function(state, last) { if (state == 'stuck') return; if (then) then(state, last); else window.location.reload(); });
		return true;
	},

	installCore: function() {
		var self = this;
		return callCoreInst('', '').then(function(r) {
			if (self.busy(r, callCoreStatus, _('Core install already running'))) return;
			if (r && r.error) return self.warn(r.error);
			self.taskModal(_('Downloading the core'), _('Getting sing-box from the internet. Takes a minute or two.'), callCoreStatus,
				function(state, last) { if (state == 'failed') self.afterFail(last, function(why) { self.coreGuide(true, why); }); else window.location.reload(); });
		}).catch(function(e) { self.fail(e); });
	},

	uploadCore: function() {
		var self = this;
		var go = function() {
			return callCoreImport('/tmp/nxsb-core-upload.tar.gz').then(function(r) {
				if (self.busy(r, callCoreStatus, _('Core install already running'), function() { go(); })) return;
				if (r && r.error) return self.warn(r.error);
				self.taskModal(_('Installing the core'), _('Checking and installing the file you uploaded.'), callCoreStatus,
					function(state, last) { if (state == 'failed') self.afterFail(last, function(why) { self.coreGuide(true, why); }); else window.location.reload(); });
			}).catch(function(e) { self.fail(e); });
		};
		return ui.uploadFile('/tmp/nxsb-core-upload.tar.gz').then(go)
			.catch(function(e) { if (e && e.message && !/aborted|cancel/i.test(e.message)) self.warn(_('Upload failed: %s').format(e.message)); });
	},

	installKmod: function(what) {
		var self = this; what = KMOD[what] ? what : 'tun';
		return callDepsInst(what).then(function(r) {
			if (self.busy(r, callDepsStatus, _('Module install already running'))) return;
			if (r && r.error) return self.warn(r.error);
			self.taskModal(_('Downloading %s').format(KMOD[what].pkg), _('Getting %s from the OpenWrt server. Takes a minute or two.').format(KMOD[what].name), callDepsStatus,
				function(state, last) { if (state == 'failed') self.afterFail(last, function(why) { self.kmodGuide(what, true, why); }); else window.location.reload(); });
		}).catch(function(e) { self.fail(e); });
	},

	uploadKmod: function(what) {
		var self = this; what = KMOD[what] ? what : 'tun';
		var go = function() {
			return callDepsImport('/tmp/nxsb-kmod-upload.ipk').then(function(r) {
				if (self.busy(r, callDepsStatus, _('Module install already running'), function() { go(); })) return;
				if (r && r.error) return self.warn(r.error);
				self.taskModal(_('Installing %s').format(KMOD[what].pkg), _('Checking and installing the file you uploaded.'), callDepsStatus,
					function(state, last) { if (state == 'failed') self.afterFail(last, function(why) { self.kmodGuide(what, true, why); }); else window.location.reload(); });
			}).catch(function(e) { self.fail(e); });
		};
		return ui.uploadFile('/tmp/nxsb-kmod-upload.ipk').then(go)
			.catch(function(e) { if (e && e.message && !/aborted|cancel/i.test(e.message)) self.warn(_('Upload failed: %s').format(e.message)); });
	},

	// BBR state in words plus the one thing to do about it; used by the Overview row and the Settings » Core row
	bbrState: function(deps, settingsUrl) {
		var self = this;
		deps = deps || {};
		if (deps.bbr_wanted == null) return [ this.badge(false, _('unknown')), ' ', _('The router did not report it. Reload the page; if it stays like this, run the diagnostics on the Log page.') ];
		if (!deps.bbr_wanted) return [ E('span', { 'style': 'background:#616161;color:#fff;padding:2px 8px;border-radius:3px;font-weight:bold' }, _('off')), ' ',
			settingsUrl ? E('a', { 'href': settingsUrl }, _('Turn on in Settings » Core')) : _('Turn the switch on and save') ];
		if (deps.bbr_active) return [ this.badge(true, _('active')) ];
		if (!deps.bbr_installed) return [ this.badge(false, _('not active')), ' ', _('The BBR module is not installed.'), ' ',
			settingsUrl ? E('a', { 'class': 'btn cbi-button cbi-button-action', 'href': settingsUrl }, _('Install')) : _('Download it or upload it from your PC:') ];
		return [ this.badge(false, _('not active')), ' ', _('The module is installed but not in use yet.'), ' ',
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': this.readonly() ? '' : null, 'click': function() { self.activateBbr(); } }, _('Activate')) ];
	},
	activateBbr: function() {
		var self = this;
		return callBbrApply().then(function(r) {
			if (r && r.error) return self.warn(r.error);
			if (r && r.ok) { self.info(_('BBR is active.')); window.setTimeout(function() { window.location.reload(); }, 1200); }
			else self.warn(_('BBR could not be activated: %s').format((r && r.reason) || '?'));
		}).catch(function(e) { self.fail(e); });
	},

	uploadSub: function() {
		var self = this;
		return ui.uploadFile('/tmp/nxsb-sub-upload.json').then(function() {
			return callSubImport('/tmp/nxsb-sub-upload.json').then(function(r) {
				if (self.busy(r, callSubStatus, _('Subscription job already running'))) return;
				if (r && r.error) return self.warn(r.error);
				self.taskModal(_('Importing config'), _('Checking the file you uploaded.'), callSubStatus, function(state, last) {
					if (state == 'done') window.location.reload(); else self.warn(_('The file was not accepted: %s').format(last || _('see the Log page')));
				});
			}).catch(function(e) { self.fail(e); });
		}).catch(function(e) { if (e && e.message && !/aborted|cancel/i.test(e.message)) self.warn(_('Upload failed: %s').format(e.message)); });
	},

	// runs the checks in the background (network probes take up to ~30 s), then shows the report with a Copy button
	diagnostics: function() {
		var self = this;
		var msg = E('p', { 'class': 'spinning' }, _('Checking… usually 15 to 30 seconds.'));
		var pre = E('pre', { 'style': 'max-height:60vh;overflow:auto;font-size:12px;white-space:pre-wrap' }, '');
		var timer = null;
		var copy = E('button', { 'class': 'btn cbi-button-action', 'disabled': '', 'click': function() {
			var t = pre.textContent, done = function() { copy.textContent = _('Copied'); };
			var fallback = function() { try { var ta = E('textarea', {}, [ t ]); document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); done(); } catch (e) { copy.textContent = _('Select the text and copy it'); } };
			if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(done).catch(fallback); else fallback();
		} }, _('Copy report'));
		var close = function() { if (timer) window.clearInterval(timer); ui.hideModal(); };
		ui.showModal(_('Diagnostics'), [ msg, pre, E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': close }, _('Close')), ' ', copy ]) ]);
		var watch = function() {
			var started = Date.now();
			timer = window.setInterval(function() {
				callDiagStatus().then(function(st) {
					pre.textContent = st.report || '';
					var age = Date.now() - started;
					if (st.state == 'done' || age > 5 * 60 * 1000) {
						window.clearInterval(timer); timer = null;
						msg.textContent = st.state == 'done' ? _('Lines starting with FAIL or WARN tell you what to do. "Copy report" and paste it to whoever helps you.') : _('Still not finished after 5 minutes; the report below is incomplete. The router is very slow or a check is stuck: run "/etc/init.d/nxsb diag" over SSH.');
						msg.classList.remove('spinning'); copy.removeAttribute('disabled');
					} else if (age > 90000) msg.textContent = _('Still running (a slow router or a slow network check). Waiting…');
				}).catch(function(e) { msg.textContent = self.errText(e); msg.classList.remove('spinning'); });
			}, 1000);
		};
		return callDiag().then(function(r) {
			if (r && r.error && /already running/.test(r.error)) { msg.textContent = _('A diagnostics run is already in progress. Showing it…'); watch(); return; }
			if (r && r.error) { msg.textContent = r.error; msg.classList.remove('spinning'); return; }
			watch();
		}).catch(function(e) { msg.textContent = self.errText(e); msg.classList.remove('spinning'); });
	},

	// result of a one-shot action in a modal whose OK reloads the page, so the text can actually be read
	resultModal: function(title, text) {
		ui.showModal(title, [ E('pre', { 'style': 'white-space:pre-wrap' }, [ text || '' ]), E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn cbi-button-action', 'click': function() { ui.hideModal(); window.location.reload(); } }, _('OK')) ]) ]);
	},

	destroy: function() {
		var self = this;
		if (!confirm(_('Stop the service and wipe the working directory (subscription, cache, downloaded rule-sets)? Settings stay.'))) return Promise.resolve();
		return callDestroy().then(function(r) { if (r && r.error) return self.warn(r.error); self.resultModal(_('Working directory'), r.output); }).catch(function(e) { self.fail(e); });
	},

	reset: function(full) {
		var self = this;
		var msg = full ? _('Full reset. Subscription, cache and settings gone, service stopped. Sure?') : _('Reset settings to defaults? Subscription URL stays.');
		if (!confirm(msg)) return Promise.resolve();
		return callReset(!!full).then(function(r) { if (r && r.error) return self.warn(r.error); self.resultModal(_('Reset'), r.output); }).catch(function(e) { self.fail(e); });
	}
});
