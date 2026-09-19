'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require nxsb.common as common';

var callLog = rpc.declare({ object: 'luci.nxsb', method: 'log', params: [ 'lines', 'all' ], reject: true });
var showAll = false;
var callCheck = rpc.declare({ object: 'luci.nxsb', method: 'check', reject: true });

return view.extend({
	load: function() { return callLog(200, false).catch(function(e) { return { log: '', error: common.errText(e) }; }); },
	render: function(r) {
		var pre = E('pre', { 'id': 'nxsb-log', 'style': 'max-height:60vh;overflow:auto;font-size:12px' }, [ r.log || r.error || _('(empty)') ]);
		var lastText = r.log || '';
		poll.add(function() {
			return callLog(200, showAll).then(function(r) {
				var t = r.log || _('(empty)');
				if (t == lastText) return;                       // untouched when nothing changed: keeps a text selection alive
				var atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 5;
				pre.textContent = t; lastText = t;
				if (atBottom) pre.scrollTop = pre.scrollHeight;
			}).catch(function(e) { pre.textContent = lastText + '\n' + _('(refresh failed: %s)').format(common.errText(e)); lastText = ''; });
		}, 3);
		var copy = E('button', { 'class': 'btn cbi-button', 'click': function() {
			var t = pre.textContent, done = function() { copy.textContent = _('Copied'); };
			var fallback = function() { try { var ta = E('textarea', {}, [ t ]); document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); done(); } catch (e) { copy.textContent = _('Select the text and copy it'); } };
			if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(done).catch(fallback); else fallback();
		} }, _('Copy'));
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Log')),
			E('p', { 'style': 'opacity:.7' }, _('Service events, core warnings and the last lines of the core download, module install and subscription jobs. Per-connection logs are in the dashboard.')),
			E('div', { 'style': 'margin-bottom:8px' }, [ E('label', {}, [ E('input', { 'type': 'checkbox', 'change': function(ev) { showAll = ev.target.checked; } }), ' ', _('Include info-level core messages') ]), ' ', copy ]),
			E('div', { 'class': 'cbi-section' }, [ pre ]),
			E('h3', {}, _('Something wrong?')),
			E('div', { 'class': 'cbi-section' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'disabled': common.readonly() ? '' : null, 'click': function() { return common.diagnostics(); } }, _('Run diagnostics')), ' ',
				E('span', { 'style': 'opacity:.7' }, _('Checks the core, DNS, tunnel, dashboard and router in one go, and gives you a report to paste.'))
			]),
			E('h3', {}, _('Configuration')),
			E('div', { 'class': 'cbi-section' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': common.readonly() ? '' : null, 'click': function() { callCheck().then(function(r) { ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap' }, [ r.output || '' ]), /rc=0/.test(r.output || '') ? 'info' : 'warning'); }).catch(function(e) { common.fail(e); }); } }, _('Validate config'))
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
