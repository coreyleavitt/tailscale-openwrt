'use strict';
'require form';
'require network';
'require tools.widgets as widgets';

return network.registerProtocol('tailscale', {
	getI18n: function() {
		return _('Tailscale VPN');
	},

	getIfname: function() {
		return 'tailscale0';
	},

	getOpkgPackage: function() {
		return 'tailscale';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (ifname == 'tailscale0');
	},

	renderFormOptions: function(s) {
		var o;

		o = s.taboption('general', form.Value, '_info', _('Status'));
		o.readonly = true;
		o.cfgvalue = function() {
			return _('Tailscale interface is managed by tailscaled. Use "tailscale status" to view connection status.');
		};
	}
});
