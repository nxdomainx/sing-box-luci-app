'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require nxsb.common as common';

var callStatus = rpc.declare({ object: 'luci.nxsb', method: 'status', reject: true });
var callGuide  = rpc.declare({ object: 'luci.nxsb', method: 'core_guide', reject: true });
var callKmodGuide = rpc.declare({ object: 'luci.nxsb', method: 'deps_guide', params: [ 'what' ], reject: true });
// a failed lookup becomes a row that says so instead of "undefined" links
function orError(p) { return p.catch(function(e) { return { error: common.errText(e) }; }); }

return view.extend({
	load: function() { return Promise.all([ orError(callGuide()), orError(callKmodGuide('tun')), orError(callStatus()), orError(callKmodGuide('bbr')) ]); },
	render: function(loaded) {
		var guide = loaded[0] || {}, kmod = loaded[1] || {}, status = loaded[2] || {}, kbbr = loaded[3] || {};
		var ro = common.readonly();
		// where to get the file when the router has no internet
		function offlineHint(k) {
			if (k.error) return E('div', { 'style': 'margin-top:4px;color:#b71c1c' }, [ _('Could not work out the download link: %s').format(k.error) ]);
			return E('div', { 'style': 'margin-top:4px;opacity:.8' }, k.url
				? [ _('Router has no internet? On your PC download '), E('a', { 'href': k.url, 'target': '_blank' }, [ k.file || k.url ]), _(' and click "Upload from PC".') ]
				: [ _('Router has no internet? On your PC open '), E('a', { 'href': (k.feed || '') + '/', 'target': '_blank' }, _('this folder')), _(', open the subfolder starting with %s, download %s and click "Upload from PC".').format(k.kernel || '?', k.file || '?') ]);
		}
		// same row for both kernel modules: state badge, Download / Upload from PC, the exact file for offline routers
		function kmodRow(what, k, installed, extra) {
			var busy = status.deps && status.deps.state == 'running';
			return E('div', {}, [
				E('div', {}, [ common.badge(installed, installed ? _('installed') : _('missing')), ' ', extra || '', extra ? ' ' : '',
					installed ? '' : E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': ro ? '' : null, 'click': function() { common.installKmod(what); } }, busy ? _('Show progress') : _('Download')), installed ? '' : ' ',
					E('button', { 'class': 'btn cbi-button', 'disabled': ro ? '' : null, 'click': function() { common.uploadKmod(what); } }, _('Upload from PC')),
					busy ? E('span', { 'style': 'margin-left:8px;opacity:.7' }, [ _('a module install is running') ]) : '' ]),
				offlineHint(k)
			]);
		}
		var m = new form.Map('nxsb', _('Settings'), _('Routing, rules and DNS come from the panel. These are router-side settings. Saving restarts the service if it is running.'));
		if (status.error) ui.addNotification(null, E('p', {}, [ _('Could not read the status: %s').format(status.error) ]), 'warning');
		var s, o;
		s = m.section(form.NamedSection, 'main', 'main');
		s.tab('general', _('General'));
		s.tab('lan', _('LAN'));
		s.tab('advanced', _('Advanced'));
		s.tab('core', _('Core'));
		s.tab('reset', _('Reset'));

		o = s.taboption('general', form.Value, 'sub_url', _('Subscription URL'), _('Your subscription link from the panel. Or upload a config file below.'));
		o.rmempty = true; o.validate = function(sid, v) { return (v == '' || /^https?:\/\/[^\/\s?#]+/.test(v)) ? true : _('must be a full link starting with http:// or https://'); };
		o = s.taboption('general', form.Button, '_sub_upload', _('Config file'), _('A sing-box config (.json) from your PC instead of a subscription URL. Auto-update is off while a file is in use; "Update subscription" goes back to the URL.'));
		o.inputtitle = _('Upload config'); o.inputstyle = 'action';
		o.onclick = function() { return common.uploadSub(); };
		if (ro) o.readonly = true;
		o = s.taboption('general', form.Value, 'auto_update', _('Auto-update (hours)'), _('Refresh the subscription every N hours. 0 = manual.'));
		o.datatype = 'uinteger'; o.default = '0';
		o = s.taboption('general', form.Flag, 'enabled', _('Start on boot'));
		o = s.taboption('general', form.ListValue, 'log_level', _('Log level'), _('Empty: whatever the panel sets.'));
		o.value('', _('from subscription')); [ 'trace', 'debug', 'info', 'warn', 'error', 'fatal' ].forEach(function(l) { o.value(l); }); o.default = ''; o.rmempty = true;

		o = s.taboption('lan', form.Flag, 'hijack_lan_dns', _('Answer LAN DNS through the core'), _('LAN DNS goes to the core. If the core is down, back to the ISP resolver.'));
		o.default = '1';
		o = s.taboption('lan', form.Flag, 'lan_dns6', _('Advertise DNS over IPv6'), _('Off = recommended. Do not turn on unless you know what you are doing. Not the same as IPv6 connectivity.'));
		o.default = '0';
		o = s.taboption('lan', form.Flag, 'lan_fakeip', _('Fake-IP for LAN devices'), _('Off = recommended. On = faster but might break some use cases.'));
		o.default = '0'; o.depends('hijack_lan_dns', '1');
		o = s.taboption('lan', form.DynamicList, 'bypass_src', _('Bypass devices'), _('Devices that skip the tunnel.'));
		o.datatype = 'or(ip4addr,cidr4)'; o.placeholder = _('add an IP or CIDR');
		o = s.taboption('lan', form.Value, 'dns_direct', _('Direct resolver'), _('Resolver for direct traffic. auto = the one from your WAN. Or an IP.'));
		o.default = 'auto'; o.placeholder = 'auto'; o.datatype = 'or("auto", ip4addr("nomask"))';

		o = s.taboption('advanced', form.ListValue, 'tun_stack', _('TUN stack'), _('system is fastest. Try gvisor only if something breaks.'));
		o.value('system'); o.value('gvisor'); o.value('mixed'); o.default = 'system';
		o = s.taboption('advanced', form.Value, 'tun_mtu', _('TUN MTU'), _('Empty = 1500.')); o.datatype = 'range(1280,65535)'; o.placeholder = '1500';
		o = s.taboption('advanced', form.Flag, 'auto_redirect', _('nftables auto-redirect'), _('nftables redirect for LAN traffic. Leave off unless you know why.'));
		o = s.taboption('advanced', form.DynamicList, 'tun_exclude', _('Keep out of the tunnel'), _('Destinations that never enter the TUN, as IP or CIDR.'));
		o.datatype = 'or(ipaddr,cidr4,cidr6)'; o.placeholder = _('add an IP or CIDR');
		o = s.taboption('general', form.Flag, 'dashboard', _('Web dashboard'), _('Web dashboard on the LAN.')); o.default = '1';
		o = s.taboption('general', form.Value, 'dashboard_host', _('Dashboard name'), _('Local name for the dashboard, port 80. The router address with the dashboard port works as well.')); o.default = 'dash.nxsb.arpa'; o.depends('dashboard', '1');
		o.datatype = 'hostname';
		o = s.taboption('advanced', form.Value, 'dashboard_ip', _('Dashboard alias address'), _('Address behind the name. Must be outside every network of this router (LAN, guest, WAN); the service checks that at start and says so in the Log.')); o.datatype = 'ip4addr("nomask")'; o.default = '10.255.255.254';
		o.validate = function(sid, v) {
			// a quick /24 sanity check against the LAN address; the service checks every interface with the real mask
			var lan = ((status.dashboard && status.dashboard.lan_ip) || '').split('/')[0];
			if (v && lan && v.split('.').slice(0, 3).join('.') == lan.split('.').slice(0, 3).join('.')) return _('this looks like it is inside your LAN (%s): pick an address outside every network of the router').format(lan);
			return true;
		};
		o = s.taboption('advanced', form.Value, 'api_port', _('Dashboard / API port')); o.datatype = 'port'; o.default = '9091';
		o = s.taboption('advanced', form.Value, 'api_secret', _('Dashboard secret'), _('Optional. Empty = no login on the LAN (the WAN side is blocked by the firewall anyway). Letters, digits and punctuation, no spaces.')); o.password = true;
		o.validate = function(sid, v) { return /^[\x21-\x7e]*$/.test(v || '') ? true : _('letters, digits and punctuation only, no spaces'); };
		o = s.taboption('advanced', form.Value, 'dns_listen_port', _('DNS listener port')); o.datatype = 'port'; o.default = '5335';
		o = s.taboption('advanced', form.Value, 'mirror', _('Core download mirror'), _('Mirror for the core download. Same path layout as the GitHub releases.'));
		o.validate = function(sid, v) { return (!v || /^https?:\/\/[^\/\s?#]+/.test(v)) ? true : _('must be a full link starting with http:// or https://'); };

		o = s.taboption('core', form.DummyValue, '_core', _('Core'));
		o.rawhtml = true; o.cfgvalue = function() {
			var g = guide || {}, c = (status && status.core) || {}, busy = c.state == 'running';
			return E('div', {}, [
				E('div', {}, [ common.badge(c.installed, c.installed ? _('installed %s').format(c.version) : _('not installed')), ' ',
					(c.channel && c.channel != 'pinned' && c.latest) ? E('span', { 'style': 'opacity:.7;margin-right:6px' }, [ _('newest %s: %s').format(c.channel, c.latest) ]) : '',
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': ro ? '' : null, 'click': function() { common.installCore(); } }, busy ? _('Show progress') : (c.installed ? _('Download again') : _('Download'))), ' ',
					E('button', { 'class': 'btn cbi-button', 'disabled': ro ? '' : null, 'click': function() { common.uploadCore(); } }, _('Upload from PC')),
					busy ? E('span', { 'style': 'margin-left:8px;opacity:.7' }, [ _('a core install is running') ]) : '' ]),
				offlineHint(g)
			]);
		};
		o = s.taboption('core', form.ListValue, 'core_channel', _('Update track'), _('Latest = looked up once a day and upgraded by itself; the service restarts when that happens.'));
		o.value('pinned', _('%s (default)').format((guide || {}).version || '?')); o.value('stable', _('Latest stable')); o.value('beta', _('Latest beta')); o.default = 'pinned';
		o = s.taboption('core', form.DummyValue, '_kmod', _('TUN module'));
		o.rawhtml = true; o.cfgvalue = function() { var d = (status && status.deps) || {}; return kmodRow('tun', kmod || {}, !!d.tun); };
		o = s.taboption('core', form.Flag, 'bbr', _('BBR congestion control'), _('Smoother uploads and video calls through the tunnel. Needs the module below; without it nothing changes.'));
		o.default = '1';
		o = s.taboption('core', form.DummyValue, '_bbr', _('BBR module'));
		o.rawhtml = true; o.depends('bbr', '1'); o.cfgvalue = function() {
			var d = (status && status.deps) || {};
			return kmodRow('bbr', kbbr || {}, !!d.bbr_installed, E('span', {}, common.bbrState(d, null)));
		};
		o = s.taboption('core', form.Button, '_destroy', _('Working directory'), _('Stops the service and wipes what the core wrote: subscription, cache, downloaded rule-sets. Settings and the service events stay.'));
		o.inputtitle = _('Destroy working directory'); o.inputstyle = 'remove';
		o.onclick = function() { return common.destroy(); };
		if (ro) o.readonly = true;
		o = s.taboption('reset', form.Button, '_reset', _('Reset settings'), _('Back to defaults, cache cleared. Subscription URL stays. Restarts if running.'));
		o.inputtitle = _('Reset to defaults'); o.inputstyle = 'remove';
		o.onclick = function() { return common.reset(false); };
		if (ro) o.readonly = true;
		o = s.taboption('reset', form.Button, '_reset_full', _('Full reset'), _('Back to a fresh install. Drops the subscription and cache too. Core binary stays.'));
		o.inputtitle = _('Full reset'); o.inputstyle = 'remove';
		o.onclick = function() { return common.reset(true); };
		if (ro) o.readonly = true;

		return m.render().then(function(node) {
			if (ro) node.insertBefore(common.roNote(), node.firstChild);
			// Overview "Install" buttons land here with #core
			if (window.location.hash == '#core') window.setTimeout(function() { var t = document.querySelector('ul.cbi-tabmenu li[data-tab="core"] a'); if (t) t.click(); }, 150);
			return node;
		});
	}
});
