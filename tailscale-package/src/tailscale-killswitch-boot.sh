#!/bin/sh
#
# Tailscale Killswitch - Firewall Boot Script
# Called by fw4 during firewall startup (before network).
#

exec /usr/sbin/tailscale-killswitch apply-rules
