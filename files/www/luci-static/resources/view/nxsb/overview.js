'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require nxsb.common as common';

var callStatus     = rpc.declare({ object: 'luci.nxsb', method: 'status', reject: true });
var callSubUpdate  = rpc.declare({ object: 'luci.nxsb', method: 'sub_update', reject: true });
var callSubStatus  = rpc.declare({ object: 'luci.nxsb', method: 'sub_status', reject: true });
var callService    = rpc.declare({ object: 'luci.nxsb', method: 'service', params: [ 'action' ], reject: true });
var callEnable     = rpc.declare({ object: 'luci.nxsb', method: 'enable_start', reject: true });
var callDisable    = rpc.declare({ object: 'luci.nxsb', method: 'disable_stop', reject: true });
var callSelect     = rpc.declare({ object: 'luci.nxsb', method: 'select', params: [ 'group', 'tag' ], reject: true });
var callUrltest    = rpc.declare({ object: 'luci.nxsb', method: 'urltest', params: [ 'group' ], reject: true });

var badge = function(ok, text) { return common.badge(ok, text); };
// LuCI keeps an empty div.modal in the page at all times; only the body class says whether one is showing
function modalOpen() { return document.body.classList.contains('modal-overlay-active'); }
function selectFocused() { return !!document.querySelector('#nxsb-status select:focus'); }
var lostNoted = false;

return view.extend({
	load: function() { return callStatus().catch(function(e) { return { error: common.errText(e) }; }); },

	refresh: function(delayMs) {
		var self = this;
		window.setTimeout(function() {
			callStatus().then(function(s) { var el = document.getElementById('nxsb-status'); if (el && !modalOpen() && !selectFocused()) self.renderStatus(el, s); }).catch(function(e) { common.fail(e); });
		}, delayMs || 0);
	},

	render: function(st) {
		var self = this;
		var v = E('div', { 'class': 'cbi-map' }, [ E('h2', {}, _('Sing-Box')), common.roNote(), E('div', { 'class': 'cbi-section' }, [ E('div', { 'id': 'nxsb-status' }) ]) ]);
		this.renderStatus(v.querySelector('#nxsb-status'), st);
		poll.add(function() {
			return callStatus().then(function(s) {
				if (lostNoted) { lostNoted = false; common.info(_('Connection to the router is back.')); }
				var el = document.getElementById('nxsb-status'); if (el && !modalOpen() && !selectFocused()) self.renderStatus(el, s);
			}).catch(function(e) { if (!lostNoted) { lostNoted = true; common.warn(_('Status refresh failed: %s').format(common.errText(e))); } });
		}, 5);
		return v;
	},

	renderStatus: function(el, st) {
		var self = this;
		if (!L.isObject(st) || st.error) {
			dom.content(el, [ E('p', { 'style': 'color:#b71c1c' }, [ _('Could not read the status: %s').format((st && st.error) || _('no answer')) ]) ]);
			return;
		}
		var ro = common.readonly();
		var running = st.service && st.service.running;
		var core = st.core || {};
		var sub = st.subscription || {};
		var deps = st.deps || {};
		var settingsCore = L.url('admin/services/nxsb/settings') + '#core';

		var groupRows = (st.groups || []).map(function(g) {
			var all = g.all || [];
			var sel = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:240px', 'disabled': (ro || !running || g.type != 'selector') ? '' : null, 'change': function(ev) {
				var tag = ev.target.value;
				callSelect(g.tag, tag).then(function(r) {
					if (r && r.error) common.warn(_('%s: %s').format(g.tag, r.error)); else common.info(_('%s → %s').format(g.tag, tag));
					self.refresh(700);
				}).catch(function(e) { common.fail(e); });
			}}, [ E('option', { 'value': '', 'disabled': '', 'selected': (!g.now || all.indexOf(g.now) < 0) ? '' : null },
				running ? _('(none)') : (g.type == 'selector' ? _('(panel default at start)') : _('(automatic)'))) ]
				.concat(all.map(function(t) { return E('option', { 'value': t, 'selected': t == g.now ? '' : null }, [ t ]); })));
			return [ E('span', {}, [ g.tag ]), E('span', {}, [ sel, ' ',
				E('button', { 'class': 'btn cbi-button', 'disabled': (ro || !running) ? '' : null, 'click': function() {
					ui.showModal(_('Testing…'), [ E('p', { 'class': 'spinning' }, [ _('Measuring latency of %s').format(g.tag) ]) ]);
					callUrltest(g.tag).then(function(r) {
						if (r && r.error) { ui.hideModal(); common.warn(_('%s: %s').format(g.tag, r.error)); return; }
						window.setTimeout(function() { ui.hideModal(); self.refresh(0); }, 6000);
					}).catch(function(e) { ui.hideModal(); common.fail(e); });
				}}, _('Test')),
				g.delay ? E('span', { 'style': 'margin-left:8px;opacity:.7' }, [ g.delay + ' ms' ]) : ''
			]) ];
		});

		var rows = [
			[ _('Service'), E('span', {}, [ badge(running, running ? _('running') : _('stopped')), ' ', running ? (st.service.pid ? _('pid %d').format(st.service.pid) : '') : (st.enabled ? _('starts on boot, not running (see Log)') : _('does not start on boot')) ]) ],
			[ _('Core'), E('span', {}, [ badge(core.installed, core.installed ? core.version : _('not installed')), ' ',
				core.installed ? _('pinned %s').format(core.pinned || '?') : E('a', { 'class': 'btn cbi-button cbi-button-action', 'href': settingsCore }, _('Install')) ]) ],
			[ _('TUN module'), E('span', {}, [ badge(deps.tun, deps.tun ? _('kmod-tun loaded') : _('kmod-tun missing')), ' ',
				deps.tun ? '' : E('a', { 'class': 'btn cbi-button cbi-button-action', 'href': settingsCore }, _('Install')) ]) ],
			[ _('BBR'), E('span', {}, common.bbrState(deps, settingsCore)) ],
			[ _('Subscription'), E('span', {}, [ badge(sub.stored, sub.stored ? _('%d nodes').format(sub.nodes) : _('not fetched')), ' ',
				(sub.source == 'file' && sub.stored) ? (sub.last_update ? _('from uploaded file, %s').format(new Date(sub.last_update * 1000).toLocaleString()) : _('from uploaded file'))
					: sub.configured ? (sub.last_update ? _('updated %s').format(new Date(sub.last_update * 1000).toLocaleString()) : '') : _('no URL set and no file uploaded (Settings)'),
				sub.last_error ? E('span', { 'style': 'color:#b71c1c;margin-left:8px' }, [ sub.last_error ]) : '' ]) ],
		];
		var dash = st.dashboard || {};
		if (dash.enabled) {
			var byIp = 'http://' + (dash.lan_ip || location.hostname) + ':' + dash.port + '/dashboard/';
			var named = !!(dash.host && dash.ip && dash.active);
			var url = named ? 'http://' + dash.host + '/dashboard/' : byIp;
			var open = url + (dash.secret ? '#s=' + encodeURIComponent(dash.secret) : '');
			rows.push([ _('Dashboard'), E('span', {}, [ running ? E('a', { 'href': open, 'target': '_blank', 'class': 'btn cbi-button cbi-button-action' }, _('Open dashboard')) : E('span', { 'style': 'opacity:.6' }, [ url + ' ' + _('(when running)') ]),
				running ? E('span', { 'style': 'margin-left:12px;opacity:.7' }, [ url ]) : '',
				(running && dash.host && !named) ? E('span', { 'style': 'margin-left:12px;color:#b71c1c' }, [ _('the name %s could not be set up, see the Log page').format(dash.host) ]) : '' ]) ]);
		}
		rows = rows.concat(groupRows);

		var missing = [];
		if (!core.installed) missing.push(_('core'));
		if (!deps.tun) missing.push(_('TUN module'));
		if (!sub.stored) missing.push(_('subscription'));
		var canStart = !missing.length && !ro;
		var actions = E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-apply', 'disabled': canStart ? null : '', 'title': missing.length ? _('Missing: %s').format(missing.join(', ')) : '', 'click': function() {
				return callEnable().then(function(r) {
					var ok = r && r.service && r.service.running;
					if (ok) common.info(_('Started.')); else common.warn(_('Did not start. See the Log page for the reason.'));
					self.refresh(500);
				}).catch(function(e) { common.fail(e); });
			}}, _('Enable & start')),
			' ',
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': (ro || !running) ? '' : null, 'click': function() {
				callService('restart').then(function(r) {
					var ok = r && r.service && r.service.running;
					if (ok) common.info(_('Restarted.')); else common.warn(_('Did not come back. See the Log page for the reason.'));
					self.refresh(500);
				}).catch(function(e) { common.fail(e); });
			} }, _('Restart')),
			' ',
			E('button', { 'class': 'btn cbi-button cbi-button-reset', 'disabled': (ro || (!st.enabled && !running)) ? '' : null, 'click': function() {
				return callDisable().then(function() { common.info(_('Stopped and disabled')); self.refresh(500); }).catch(function(e) { common.fail(e); });
			}}, _('Stop & disable')),
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': (ro || !sub.configured) ? '' : null, 'click': function() {
				callSubUpdate().then(function(r) {
					if (common.busy(r, callSubStatus, _('Subscription job already running'), function() { self.refresh(0); })) return;
					if (r && r.error) return common.warn(r.error);
					common.taskModal(_('Updating subscription'), _('Fetching the config from the panel.'), callSubStatus, function(state, last) {
						if (state == 'done' && running) common.info(_('Restart to apply the new subscription.'));
						else if (state == 'failed') common.warn(_('Subscription update failed: %s').format(last || _('see the Log page')));
						self.refresh(0);
					});
				}).catch(function(e) { common.fail(e); });
			}}, _('Update subscription')),
			missing.length ? E('span', { 'style': 'margin-left:12px;opacity:.7' }, [ _('Enable & start needs: %s').format(missing.join(', ')) ]) : ''
		]);

		dom.content(el, [
			E('table', { 'class': 'table' }, rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'style': 'width:180px;font-weight:bold' }, r[0]), E('td', { 'class': 'td left' }, r[1]) ]);
			})),
			actions,
			E('p', { 'style': 'opacity:.6;font-size:12px' }, [ _('nxsb %s').format(st.app_version || '') ])
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
