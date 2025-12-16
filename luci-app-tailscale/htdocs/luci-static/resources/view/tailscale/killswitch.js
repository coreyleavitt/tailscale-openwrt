'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require fs';

var callTailscaleKillswitch = rpc.declare({
	object: 'luci.tailscale',
	method: 'killswitch',
	params: ['action']
});

var callTailscaleStatus = rpc.declare({
	object: 'luci.tailscale',
	method: 'status'
});

var callTailscaleVerbose = rpc.declare({
	object: 'luci.tailscale',
	method: 'status_verbose'
});

var callTailscaleInfo = rpc.declare({
	object: 'luci.tailscale',
	method: 'tailscale_info'
});

var callGetExitNode = rpc.declare({
	object: 'luci.tailscale',
	method: 'get_exit_node'
});

var callSetExitNode = rpc.declare({
	object: 'luci.tailscale',
	method: 'set_exit_node',
	params: ['node']
});

var callListExitNodes = rpc.declare({
	object: 'luci.tailscale',
	method: 'list_exit_nodes'
});

var callGetAcceptRoutes = rpc.declare({
	object: 'luci.tailscale',
	method: 'get_accept_routes'
});

var callSetAcceptRoutes = rpc.declare({
	object: 'luci.tailscale',
	method: 'set_accept_routes',
	params: ['enabled']
});

var callGetAdvertiseRoutes = rpc.declare({
	object: 'luci.tailscale',
	method: 'get_advertise_routes'
});

var callSetAdvertiseRoutes = rpc.declare({
	object: 'luci.tailscale',
	method: 'set_advertise_routes',
	params: ['routes']
});

var callGetSSH = rpc.declare({
	object: 'luci.tailscale',
	method: 'get_ssh'
});

var callSetSSH = rpc.declare({
	object: 'luci.tailscale',
	method: 'set_ssh',
	params: ['enabled']
});

var callGetFullStatus = rpc.declare({
	object: 'luci.tailscale',
	method: 'get_full_status'
});

return view.extend({
	load: function() {
		return Promise.all([
			callGetFullStatus().catch(function(err) {
				return {
					connected: false,
					version: 'Unknown',
					exit_node: '',
					accept_routes: 'false',
					advertise_routes: '',
					ssh: 'false',
					killswitch_status: 'Error: ' + err.message
				};
			}),
			callListExitNodes().catch(function(err) {
				return { nodes: [] };
			})
		]);
	},

	updateStatus: function() {
		var self = this;
		return callGetFullStatus().then(function(fullStatus) {
			self.updateUI(fullStatus);
		}).catch(function(err) {
			console.error('Error updating status:', err);
		});
	},

	updateUI: function(fullStatus) {
		// fullStatus now contains: connected, version, exit_node, accept_routes, advertise_routes, ssh, killswitch_status

		// Update killswitch status
		var isEnabled = fullStatus.killswitch_status && fullStatus.killswitch_status.includes('ENABLED');
		var ksStatus = document.querySelector('.killswitch-status');
		if (ksStatus) {
			ksStatus.className = 'killswitch-status ' + (isEnabled ? 'label label-success' : 'label label-default');
			ksStatus.textContent = isEnabled ? _('ENABLED') : _('DISABLED');
		}

		// Update connection status
		var connStatus = document.querySelector('.connection-status');
		if (connStatus) {
			var tsConnected = fullStatus.connected || false;
			connStatus.className = 'connection-status ' + (tsConnected ? 'label label-success' : 'label label-warning');
			connStatus.textContent = tsConnected ? _('Connected') : _('Disconnected');
		}

		// Update current exit node status - show actual node name
		var exitNodeStatus = document.querySelector('.current-exit-node-status');
		if (exitNodeStatus) {
			var currentExitNode = fullStatus.exit_node || '';
			var hasExitNode = currentExitNode && currentExitNode !== 'none' && currentExitNode !== 'None';
			exitNodeStatus.className = 'current-exit-node-status ' + (hasExitNode ? 'label label-success' : 'label label-default');
			exitNodeStatus.style.cssText = 'padding: 5px 10px; border-radius: 3px; font-weight: bold;';
			exitNodeStatus.textContent = hasExitNode ? currentExitNode : _('None');
		}

		// Don't update dropdown during polling - only on page load and after Apply
		// This prevents interference with user selection

		// Update accept routes status
		var acceptStatus = document.querySelector('.accept-routes-status');
		var acceptBtn = document.querySelector('.accept-routes-btn');
		if (acceptStatus && acceptBtn) {
			var acceptRoutes = fullStatus.accept_routes === 'true' || fullStatus.accept_routes === true;
			acceptStatus.className = 'accept-routes-status ' + (acceptRoutes ? 'label label-success' : 'label label-default');
			acceptStatus.textContent = acceptRoutes ? _('ENABLED') : _('DISABLED');
			acceptBtn.textContent = acceptRoutes ? _('Disable') : _('Enable');
			acceptBtn.className = 'accept-routes-btn btn ' + (acceptRoutes ? 'cbi-button-negative' : 'cbi-button-positive');
		}

		// Update SSH status
		var sshStatus = document.querySelector('.ssh-status');
		var sshBtn = document.querySelector('.ssh-btn');
		if (sshStatus && sshBtn) {
			var sshEnabled = fullStatus.ssh === 'true' || fullStatus.ssh === true;
			sshStatus.className = 'ssh-status ' + (sshEnabled ? 'label label-success' : 'label label-default');
			sshStatus.textContent = sshEnabled ? _('ENABLED') : _('DISABLED');
			sshBtn.textContent = sshEnabled ? _('Disable') : _('Enable');
			sshBtn.className = 'ssh-btn btn ' + (sshEnabled ? 'cbi-button-negative' : 'cbi-button-positive');
		}
	},

	render: function(data) {
		var fullStatus = data[0] || {};
		var exitNodesData = data[1] || {};

		// Extract data from consolidated status
		var isEnabled = fullStatus.killswitch_status && fullStatus.killswitch_status.includes('ENABLED');
		var tsConnected = fullStatus.connected || false;
		var tsVersion = fullStatus.version || 'Unknown';
		var currentExitNode = fullStatus.exit_node || 'none';
		var availableExitNodes = exitNodesData.nodes || [];
		var acceptRoutes = fullStatus.accept_routes === 'true' || fullStatus.accept_routes === true;
		var advertiseRoutes = fullStatus.advertise_routes || '';
		var sshEnabled = fullStatus.ssh === 'true' || fullStatus.ssh === true;

		var m, s;

		m = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Tailscale Management')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'Manage Tailscale VPN connection and exit node killswitch.'
			))
		]);

		// Tailscale Connection Status Section
		var connectionSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Tailscale Connection')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Status:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', {
						'class': 'connection-status ' + (tsConnected ? 'label label-success' : 'label label-warning'),
						'style': 'padding: 5px 10px; border-radius: 3px; font-weight: bold;'
					}, tsConnected ? _('Connected') : _('Disconnected'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Version:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('code', {}, tsVersion)
				])
			])
		]);

		// Killswitch Section
		var verboseContainer = E('div', {
			'id': 'verbose-details',
			'style': 'display: none; margin-top: 10px;'
		});

		var killswitchSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Exit Node Killswitch')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Killswitch:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', {
						'class': 'killswitch-status ' + (isEnabled ? 'label label-success' : 'label label-default'),
						'style': 'padding: 5px 10px; border-radius: 3px; font-weight: bold;'
					}, isEnabled ? _('ENABLED') : _('DISABLED'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Details:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button',
						'click': function(ev) {
							var container = document.getElementById('verbose-details');
							var btn = ev.target;
							if (container.style.display === 'none') {
								// Load verbose status
								callTailscaleVerbose().then(function(result) {
									var verboseResult = typeof result === 'string' ? result : (result.result || '');
									container.innerHTML = '';
									container.appendChild(E('pre', {
										'style': 'background: #f5f5f5; padding: 15px; border-radius: 3px; overflow-x: auto;'
									}, verboseResult));
									container.style.display = 'block';
									btn.textContent = _('Hide Details');
								}).catch(function(err) {
									container.innerHTML = '';
									container.appendChild(E('p', { 'class': 'error' }, 'Error: ' + err.message));
									container.style.display = 'block';
								});
							} else {
								container.style.display = 'none';
								btn.textContent = _('Show Details');
							}
						}
					}, _('Show Details')),
					verboseContainer
				])
			]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Control:')),
			E('div', { 'class': 'cbi-value-field' }, [
				E('button', {
					'class': 'btn cbi-button-positive ks-enable-btn',
					'style': 'margin-right: 10px;',
					'disabled': isEnabled ? '' : null,
					'click': ui.createHandlerFn(this, function(ev) {
						var btn = ev.target;
						btn.disabled = true;
						return callTailscaleKillswitch('enable').then(function(res) {
							ui.addNotification(null, E('p', _('Killswitch enabled successfully')), 'info');
							return callGetFullStatus().then(function(fullStatus) {
								var ksStatus = document.querySelector('.killswitch-status');
								if (ksStatus) {
									var newIsEnabled = fullStatus.killswitch_status && fullStatus.killswitch_status.includes('ENABLED');
									ksStatus.className = 'killswitch-status ' + (newIsEnabled ? 'label label-success' : 'label label-default');
									ksStatus.textContent = newIsEnabled ? _('ENABLED') : _('DISABLED');
								}
								// Update button states
								var enableBtn = document.querySelector('.ks-enable-btn');
								var disableBtn = document.querySelector('.ks-disable-btn');
								if (enableBtn && disableBtn) {
									enableBtn.disabled = newIsEnabled;
									disableBtn.disabled = !newIsEnabled;
								}
							});
						}).catch(function(err) {
							ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
							// Re-query actual state on error instead of trusting closure
							return callGetFullStatus().then(function(fullStatus) {
								var actuallyEnabled = fullStatus.killswitch_status && fullStatus.killswitch_status.includes('ENABLED');
								var enableBtn = document.querySelector('.ks-enable-btn');
								var disableBtn = document.querySelector('.ks-disable-btn');
								if (enableBtn && disableBtn) {
									enableBtn.disabled = actuallyEnabled;
									disableBtn.disabled = !actuallyEnabled;
								}
							}).catch(function() {
								// Fallback to closure if re-query fails
								btn.disabled = isEnabled;
							});
						});
					})
				}, _('Enable Killswitch')),
				E('button', {
					'class': 'btn cbi-button-negative ks-disable-btn',
					'disabled': !isEnabled ? '' : null,
					'click': ui.createHandlerFn(this, function(ev) {
						var btn = ev.target;
						btn.disabled = true;
						return callTailscaleKillswitch('disable').then(function(res) {
							ui.addNotification(null, E('p', _('Killswitch disabled successfully')), 'info');
							return callGetFullStatus().then(function(fullStatus) {
								var ksStatus = document.querySelector('.killswitch-status');
								if (ksStatus) {
									var newIsEnabled = fullStatus.killswitch_status && fullStatus.killswitch_status.includes('ENABLED');
									ksStatus.className = 'killswitch-status ' + (newIsEnabled ? 'label label-success' : 'label label-default');
									ksStatus.textContent = newIsEnabled ? _('ENABLED') : _('DISABLED');
								}
								// Update button states
								var enableBtn = document.querySelector('.ks-enable-btn');
								var disableBtn = document.querySelector('.ks-disable-btn');
								if (enableBtn && disableBtn) {
									enableBtn.disabled = newIsEnabled;
									disableBtn.disabled = !newIsEnabled;
								}
							});
						}).catch(function(err) {
							ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
							// Re-query actual state on error instead of trusting closure
							return callGetFullStatus().then(function(fullStatus) {
								var actuallyEnabled = fullStatus.killswitch_status && fullStatus.killswitch_status.includes('ENABLED');
								var enableBtn = document.querySelector('.ks-enable-btn');
								var disableBtn = document.querySelector('.ks-disable-btn');
								if (enableBtn && disableBtn) {
									enableBtn.disabled = actuallyEnabled;
									disableBtn.disabled = !actuallyEnabled;
								}
							}).catch(function() {
								// Fallback to closure if re-query fails
								btn.disabled = !isEnabled;
							});
						});
					})
				}, _('Disable Killswitch'))
			])
		]),
		]);

		// Exit Node Configuration Section
		var hasExitNode = currentExitNode && currentExitNode !== 'none' && currentExitNode !== 'None';
		var exitNodeSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Exit Node Configuration')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Exit Node Status:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', {
						'class': 'current-exit-node-status ' + (hasExitNode ? 'label label-success' : 'label label-default'),
						'style': 'padding: 5px 10px; border-radius: 3px; font-weight: bold;'
					}, hasExitNode ? currentExitNode : _('None'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Select Exit Node:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('select', {
						'id': 'exit-node-select',
						'class': 'cbi-input-select'
					}, [
						E('option', {
							value: 'none',
							selected: (!currentExitNode || currentExitNode === 'none' || currentExitNode === 'None')
						}, _('None (Disable)')),
					].concat(availableExitNodes.map(function(node) {
						return E('option', {
							value: node,
							selected: node === currentExitNode
						}, node);
					}))),
					E('button', {
						'class': 'btn cbi-button-apply exit-node-apply-btn',
						'style': 'margin-left: 10px;',
						'click': ui.createHandlerFn(this, function(ev) {
							var select = document.getElementById('exit-node-select');
							var node = select.value;
							var btn = ev.target;
							var originalText = btn.textContent;
							btn.disabled = true;
							btn.textContent = _('Applying...');
							return callSetExitNode(node).then(function(res) {
								ui.addNotification(null, E('p', _('Exit node updated')), 'info');
								return callGetFullStatus().then(function(fullStatus) {
									// Update exit node status indicator
									var exitNodeStatus = document.querySelector('.current-exit-node-status');
									if (exitNodeStatus) {
										var currentExitNode = fullStatus.exit_node || '';
										var hasExitNode = currentExitNode && currentExitNode !== 'none' && currentExitNode !== 'None';
										exitNodeStatus.className = 'current-exit-node-status ' + (hasExitNode ? 'label label-success' : 'label label-default');
										exitNodeStatus.style.cssText = 'padding: 5px 10px; border-radius: 3px; font-weight: bold;';
										exitNodeStatus.textContent = hasExitNode ? currentExitNode : _('None');
									}
									// Update dropdown selection to match
									var exitNodeSelect = document.getElementById('exit-node-select');
									if (exitNodeSelect) {
										var currentExitNode = fullStatus.exit_node || 'none';
										exitNodeSelect.value = currentExitNode;
									}
								});
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
							}).finally(function() {
								btn.disabled = false;
								btn.textContent = originalText;
							});
						})
					}, _('Apply'))
				])
			])
		]);

		// Route Configuration Section
		var routeConfigSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('Route Configuration')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Accept Routes:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', {
						'class': 'accept-routes-status ' + (acceptRoutes ? 'label label-success' : 'label label-default'),
						'style': 'padding: 5px 10px; border-radius: 3px; font-weight: bold; margin-right: 10px;'
					}, acceptRoutes ? _('ENABLED') : _('DISABLED')),
					E('button', {
						'class': 'accept-routes-btn btn ' + (acceptRoutes ? 'cbi-button-negative' : 'cbi-button-positive'),
						'click': ui.createHandlerFn(this, function(ev) {
							var btn = ev.target;
							// Determine current state from button text instead of closure variable
							var currentlyEnabled = btn.textContent.trim() === 'Disable';
							var enabled = !currentlyEnabled;
							btn.disabled = true;
							return callSetAcceptRoutes(enabled ? 'true' : 'false').then(function(res) {
								ui.addNotification(null, E('p', _('Accept routes %s').format(enabled ? 'enabled' : 'disabled')), 'info');
								return callGetAcceptRoutes().then(function(result) {
									var acceptStatus = document.querySelector('.accept-routes-status');
									var acceptBtn = document.querySelector('.accept-routes-btn');
									if (acceptStatus && acceptBtn) {
										var newAcceptRoutes = result.accept_routes === 'true' || result.accept_routes === true;
										acceptStatus.className = 'accept-routes-status ' + (newAcceptRoutes ? 'label label-success' : 'label label-default');
										acceptStatus.textContent = newAcceptRoutes ? _('ENABLED') : _('DISABLED');
										acceptBtn.textContent = newAcceptRoutes ? _('Disable') : _('Enable');
										acceptBtn.className = 'accept-routes-btn btn ' + (newAcceptRoutes ? 'cbi-button-negative' : 'cbi-button-positive');
									}
								});
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
							}).finally(function() {
								btn.disabled = false;
							});
						})
					}, acceptRoutes ? _('Disable') : _('Enable'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Advertise Routes:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'id': 'advertise-routes-input',
						'type': 'text',
						'class': 'cbi-input-text',
						'value': advertiseRoutes,
						'placeholder': 'e.g. 192.168.1.0/24,10.0.0.0/8',
						'style': 'width: 300px;'
					}),
					E('button', {
						'class': 'btn cbi-button-apply advertise-routes-apply-btn',
						'style': 'margin-left: 10px;',
						'click': ui.createHandlerFn(this, function(ev) {
							var input = document.getElementById('advertise-routes-input');
							var routes = input.value.trim();
							var btn = ev.target;

							// Client-side validation for CIDR format (IPv4 and IPv6)
							if (routes) {
								var cidrList = routes.split(',');
								var ipv4CidrRegex = /^([0-9]{1,3}\.){3}[0-9]{1,3}\/([0-9]|[1-2][0-9]|3[0-2])$/;
								var ipv6CidrRegex = /^[0-9a-fA-F:]+\/([0-9]{1,2}|1[0-1][0-9]|12[0-8])$/;

								for (var i = 0; i < cidrList.length; i++) {
									var cidr = cidrList[i].trim();

									// Check if IPv6 (contains colon)
									if (cidr.indexOf(':') !== -1) {
										if (!ipv6CidrRegex.test(cidr)) {
											ui.addNotification(null, E('p', _('Invalid IPv6 CIDR format: %s').format(cidr)), 'error');
											return Promise.resolve();
										}
									} else {
										// IPv4 validation
										if (!ipv4CidrRegex.test(cidr)) {
											ui.addNotification(null, E('p', _('Invalid IPv4 CIDR format: %s').format(cidr)), 'error');
											return Promise.resolve();
										}

										// Validate octets are 0-255
										var parts = cidr.split('/')[0].split('.');
										for (var j = 0; j < parts.length; j++) {
											if (parseInt(parts[j]) > 255) {
												ui.addNotification(null, E('p', _('Invalid octet in CIDR: %s').format(cidr)), 'error');
												return Promise.resolve();
											}
										}
									}
								}
							}

							var originalText = btn.textContent;
							btn.disabled = true;
							btn.textContent = _('Applying...');
							return callSetAdvertiseRoutes(routes).then(function(res) {
								if (res.result && res.result.includes('Error')) {
									ui.addNotification(null, E('p', res.result), 'error');
								} else {
									ui.addNotification(null, E('p', _('Advertised routes updated')), 'info');
								}
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
							}).finally(function() {
								btn.disabled = false;
								btn.textContent = originalText;
							});
						})
					}, _('Apply'))
				])
			])
		]);

		// SSH Configuration Section
		var sshSection = E('div', { 'class': 'cbi-section' }, [
			E('legend', {}, _('SSH Configuration')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('SSH over Tailscale:')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', {
						'class': 'ssh-status ' + (sshEnabled ? 'label label-success' : 'label label-default'),
						'style': 'padding: 5px 10px; border-radius: 3px; font-weight: bold; margin-right: 10px;'
					}, sshEnabled ? _('ENABLED') : _('DISABLED')),
					E('button', {
						'class': 'ssh-btn btn ' + (sshEnabled ? 'cbi-button-negative' : 'cbi-button-positive'),
						'click': ui.createHandlerFn(this, function(ev) {
							var btn = ev.target;
							// Determine current state from button text instead of closure variable
							var currentlyEnabled = btn.textContent.trim() === 'Disable';
							var enabled = !currentlyEnabled;
							btn.disabled = true;
							return callSetSSH(enabled ? 'true' : 'false').then(function(res) {
								ui.addNotification(null, E('p', _('SSH %s').format(enabled ? 'enabled' : 'disabled')), 'info');
								return callGetSSH().then(function(result) {
									var sshStatus = document.querySelector('.ssh-status');
									var sshBtn = document.querySelector('.ssh-btn');
									if (sshStatus && sshBtn) {
										var newSshEnabled = result.ssh === 'true' || result.ssh === true;
										sshStatus.className = 'ssh-status ' + (newSshEnabled ? 'label label-success' : 'label label-default');
										sshStatus.textContent = newSshEnabled ? _('ENABLED') : _('DISABLED');
										sshBtn.textContent = newSshEnabled ? _('Disable') : _('Enable');
										sshBtn.className = 'ssh-btn btn ' + (newSshEnabled ? 'cbi-button-negative' : 'cbi-button-positive');
									}
								});
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
							}).finally(function() {
								btn.disabled = false;
							});
						})
					}, sshEnabled ? _('Disable') : _('Enable'))
				])
			])
		]);

		// Start polling for real-time updates every 5 seconds
		poll.add(L.bind(this.updateStatus, this), 5);

		return E([m, connectionSection, killswitchSection, exitNodeSection, routeConfigSection, sshSection]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
