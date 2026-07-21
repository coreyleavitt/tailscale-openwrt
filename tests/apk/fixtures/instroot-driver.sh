#!/bin/sh
# tests/apk/fixtures/instroot-driver.sh
#
# Runs INSIDE the disposable test container (see tests/apk/instroot.sh),
# never on the real host. Exercises tailscale.postinst/.prerm/.postrm from
# /src (a read-only bind mount of tailscale-package/src) against:
#   - a BAKE scenario: IPKG_INSTROOT set to a scratch dir, simulating an
#     offline/ImageBuilder install -- must redirect persistent state into
#     the scratch root and never touch the container's real /etc or invoke
#     a live service reload/start.
#   - a LIVE scenario: IPKG_INSTROOT unset, simulating a normal on-device
#     install -- must behave exactly as before the guard (RFC
#     docs/rfc-apk-builds.md §4.1's "byte-equivalent when unset" rule).
#
# `uci`/`logger` on PATH are the tests/apk/fixtures stubs (see uci-stub's
# header for exactly what subset of uci it implements). `/etc/init.d/*` are
# replaced with sentinel scripts that record their own invocation instead of
# doing anything real, so "was a live reload attempted" is a direct,
# unambiguous assertion rather than an inference from side effects.
#
# Output protocol: one "CHECK <name> PASS" or "CHECK <name> FAIL <detail>"
# line per assertion; tests/apk/instroot.sh (running on the host) captures
# this container's stdout and maps each line onto lib.sh's log_info/log_fail.

set -u

# Exported once for the whole script (a `PATH=... cmd` prefix only covers
# that one command, not the driver's own later `uci ...` assertion calls --
# every invocation below, both the maintainer scripts and this script's own
# checks, needs the stubbed uci/logger ahead of PATH).
export PATH="/fixtures/bin:$PATH"

SRC=/src
SENTINEL=/tmp/sentinels/calls

# pass <name>            -- unconditional PASS
# fail <name> [detail]   -- unconditional FAIL
pass() { echo "CHECK $1 PASS"; }
fail() { _n="$1"; shift; echo "CHECK ${_n} FAIL $*"; }

# check_rc_zero <name> <rc>       -- PASS iff rc == 0
# check_rc_nonzero <name> <rc>    -- PASS iff rc != 0 (i.e. the preceding
#                                     command was expected to fail)
check_rc_zero() {
    if [ "$2" -eq 0 ]; then
        pass "$1"
    else
        fail "$1" "exit code $2, expected 0"
        [ -n "${3:-}" ] && [ -f "$3" ] && { echo "--- $3 ---"; cat "$3"; echo "--- end $3 ---"; }
    fi
}
check_rc_nonzero() {
    if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "exit code 0, expected nonzero"; fi
}

check_eq() {
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi
}

check_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected to contain '$2', got: $3" ;;
    esac
}

check_not_contains() {
    case "$3" in
        *"$2"*) fail "$1" "expected NOT to contain '$2', got: $3" ;;
        *) pass "$1" ;;
    esac
}

# --- fixture setup --------------------------------------------------------

mkdir -p /tmp/sentinels /etc/config /etc/rc.d /etc/init.d

cat > /etc/init.d/_sentinel <<'EOF'
#!/bin/sh
echo "$(basename "$0") $*" >> /tmp/sentinels/calls
exit 0
EOF
chmod 755 /etc/init.d/_sentinel
for svc in network firewall tailscale dnsmasq; do
    cp /etc/init.d/_sentinel "/etc/init.d/${svc}"
    chmod 755 "/etc/init.d/${svc}"
done

seed_enabled_tailscale_config() {
    # $1 = confdir (either the real /etc/config, or a scratch instroot's)
    mkdir -p "$1"
    printf 'S\tconfig\ttailscale\nO\tconfig\tenabled\t1\n' > "$1/tailscale"
}

reset_sentinel() {
    rm -f "$SENTINEL"
}

sentinel_calls() {
    cat "$SENTINEL" 2>/dev/null || true
}

# =====================================================================
# Scenario 1: BAKE (IPKG_INSTROOT set) -- postinst
# =====================================================================
INSTROOT=$(mktemp -d)
seed_enabled_tailscale_config "$INSTROOT/etc/config"
reset_sentinel

IPKG_INSTROOT="$INSTROOT" sh "$SRC/tailscale.postinst" >/tmp/bake-postinst.log 2>&1
rc=$?
check_rc_zero "bake_postinst_exit_zero" "$rc" "/tmp/bake-postinst.log"

# --- negatives: nothing on the real host was touched ---
uci -q get network.tailscale >/dev/null 2>&1
check_rc_nonzero "bake_postinst_host_network_untouched" "$?"

uci -q get firewall.tailscale_zone >/dev/null 2>&1
check_rc_nonzero "bake_postinst_host_firewall_untouched" "$?"

if [ -e /etc/rc.d/S99tailscale ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_postinst_host_rcd_symlink_absent" "$rc"

if [ -d /etc/tailscale ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_postinst_host_statedir_absent" "$rc"

if [ -f "$SENTINEL" ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_postinst_no_service_reload_or_start" "$rc"

# --- positives: scratch root correctly configured ---
TYPE=$(uci -c "$INSTROOT/etc/config" -q get network.tailscale 2>/dev/null)
check_eq "bake_postinst_instroot_network_section_type" "interface" "$TYPE"

PROTO=$(uci -c "$INSTROOT/etc/config" -q get network.tailscale.proto 2>/dev/null)
check_eq "bake_postinst_instroot_network_proto" "none" "$PROTO"

DEVICE=$(uci -c "$INSTROOT/etc/config" -q get network.tailscale.device 2>/dev/null)
check_eq "bake_postinst_instroot_network_device" "tailscale0" "$DEVICE"

ZTYPE=$(uci -c "$INSTROOT/etc/config" -q get firewall.tailscale_zone 2>/dev/null)
check_eq "bake_postinst_instroot_firewall_zone_type" "zone" "$ZTYPE"

KSTYPE=$(uci -c "$INSTROOT/etc/config" -q get firewall.tailscale_killswitch 2>/dev/null)
check_eq "bake_postinst_instroot_killswitch_include_type" "include" "$KSTYPE"

KSPATH=$(uci -c "$INSTROOT/etc/config" -q get firewall.tailscale_killswitch.path 2>/dev/null)
check_eq "bake_postinst_instroot_killswitch_include_path" "/usr/sbin/tailscale-killswitch-boot" "$KSPATH"

if [ -L "$INSTROOT/etc/rc.d/S99tailscale" ]; then rc=0; else rc=1; fi
check_rc_zero "bake_postinst_instroot_rcd_start_symlink_exists" "$rc"

if [ -L "$INSTROOT/etc/rc.d/K10tailscale" ]; then rc=0; else rc=1; fi
check_rc_zero "bake_postinst_instroot_rcd_stop_symlink_exists" "$rc"

LINK_TARGET=$(readlink "$INSTROOT/etc/rc.d/S99tailscale" 2>/dev/null)
check_eq "bake_postinst_instroot_rcd_symlink_target" "../init.d/tailscale" "$LINK_TARGET"

if [ -d "$INSTROOT/etc/tailscale" ]; then rc=0; else rc=1; fi
check_rc_zero "bake_postinst_instroot_statedir_created" "$rc"

# H5: has_wwan detection reads the BUILD HOST's /sys/class/net, not the
# target device's, so (like the mem_limit/gogc RAM read) it must be
# deferred under an install-root bake rather than baked in permanently.
uci -c "$INSTROOT/etc/config" -q get tailscale.hardware.has_wwan >/dev/null 2>&1
check_rc_nonzero "bake_postinst_instroot_has_wwan_absent" "$?"

# =====================================================================
# Scenario 2: BAKE -- postrm, uninstalling from the SAME scratch root
# (host is still pristine at this point -- nothing has touched it yet)
# =====================================================================
reset_sentinel

# M5: seed all 4 killswitch firewall sections (the 4th, allow_ts_traffic, is
# created by tailscale-killswitch.sh's apply_blocking_rules -- postinst
# never creates it, so it must be seeded here to exercise postrm's cleanup
# of it) so postrm's removal of all 4 is actually exercised, not just 3.
uci -c "$INSTROOT/etc/config" set firewall.lan_to_wan_block=rule
uci -c "$INSTROOT/etc/config" set firewall.block_wan_dns=rule
uci -c "$INSTROOT/etc/config" set firewall.allow_ts_dns=rule
uci -c "$INSTROOT/etc/config" set firewall.allow_ts_traffic=rule

IPKG_INSTROOT="$INSTROOT" sh "$SRC/tailscale.postrm" >/tmp/bake-postrm.log 2>&1
rc=$?
check_rc_zero "bake_postrm_exit_zero" "$rc" "/tmp/bake-postrm.log"

uci -c "$INSTROOT/etc/config" -q get network.tailscale >/dev/null 2>&1
check_rc_nonzero "bake_postrm_instroot_network_section_removed" "$?"

uci -c "$INSTROOT/etc/config" -q get firewall.tailscale_zone >/dev/null 2>&1
check_rc_nonzero "bake_postrm_instroot_firewall_zone_removed" "$?"

# M5: all 4 killswitch firewall sections must be gone, not just 3.
for _sec in lan_to_wan_block block_wan_dns allow_ts_dns allow_ts_traffic; do
    uci -c "$INSTROOT/etc/config" -q get "firewall.${_sec}" >/dev/null 2>&1
    check_rc_nonzero "bake_postrm_instroot_killswitch_${_sec}_removed" "$?"
done

if [ -e "$INSTROOT/etc/rc.d/S99tailscale" ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_postrm_instroot_rcd_start_symlink_removed" "$rc"

if [ -e "$INSTROOT/etc/rc.d/K10tailscale" ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_postrm_instroot_rcd_stop_symlink_removed" "$rc"

uci -q get network.tailscale >/dev/null 2>&1
check_rc_nonzero "bake_postrm_host_network_still_untouched" "$?"

if [ -f "$SENTINEL" ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_postrm_no_service_reload" "$rc"

# =====================================================================
# Scenario 3: BAKE -- prerm (only mutation is `/etc/init.d/tailscale stop`)
# =====================================================================
reset_sentinel

IPKG_INSTROOT="$INSTROOT" sh "$SRC/tailscale.prerm" >/tmp/bake-prerm.log 2>&1
rc=$?
check_rc_zero "bake_prerm_exit_zero" "$rc" "/tmp/bake-prerm.log"

if [ -f "$SENTINEL" ]; then rc=0; else rc=1; fi
check_rc_nonzero "bake_prerm_no_service_stop" "$rc"

# =====================================================================
# Scenario 4: LIVE (IPKG_INSTROOT unset) -- postinst must behave exactly as
# before the guard: real host uci config populated, real service
# reload/enable/start invoked.
# =====================================================================
seed_enabled_tailscale_config /etc/config
reset_sentinel

sh "$SRC/tailscale.postinst" >/tmp/live-postinst.log 2>&1
rc=$?
check_rc_zero "live_postinst_exit_zero" "$rc" "/tmp/live-postinst.log"

TYPE=$(uci -q get network.tailscale 2>/dev/null)
check_eq "live_postinst_host_network_section_type" "interface" "$TYPE"

PROTO=$(uci -q get network.tailscale.proto 2>/dev/null)
check_eq "live_postinst_host_network_proto" "none" "$PROTO"

ZTYPE=$(uci -q get firewall.tailscale_zone 2>/dev/null)
check_eq "live_postinst_host_firewall_zone_type" "zone" "$ZTYPE"

KSTYPE=$(uci -q get firewall.tailscale_killswitch 2>/dev/null)
check_eq "live_postinst_host_killswitch_include_type" "include" "$KSTYPE"

if [ -d /etc/tailscale ]; then rc=0; else rc=1; fi
check_rc_zero "live_postinst_host_statedir_created" "$rc"

CALLS=$(sentinel_calls)
check_contains "live_postinst_network_reload_called" "network reload" "$CALLS"
check_contains "live_postinst_firewall_reload_called" "firewall reload" "$CALLS"
check_contains "live_postinst_service_enable_called" "tailscale enable" "$CALLS"
check_contains "live_postinst_service_start_called" "tailscale start" "$CALLS"

# =====================================================================
# Scenario 5: LIVE -- prerm must still stop the (notional) live service
# =====================================================================
reset_sentinel

sh "$SRC/tailscale.prerm" >/tmp/live-prerm.log 2>&1
rc=$?
check_rc_zero "live_prerm_exit_zero" "$rc" "/tmp/live-prerm.log"

CALLS=$(sentinel_calls)
check_contains "live_prerm_service_stop_called" "tailscale stop" "$CALLS"

# =====================================================================
# Scenario 6: LIVE -- postrm must clean up the real host config and still
# reload the live firewall/network
# =====================================================================
reset_sentinel

# M5: seed all 4 killswitch firewall sections (see Scenario 2's comment --
# allow_ts_traffic is created by tailscale-killswitch.sh, not postinst) so
# the live postrm path exercises removing all 4 too.
uci set firewall.lan_to_wan_block=rule
uci set firewall.block_wan_dns=rule
uci set firewall.allow_ts_dns=rule
uci set firewall.allow_ts_traffic=rule

sh "$SRC/tailscale.postrm" >/tmp/live-postrm.log 2>&1
rc=$?
check_rc_zero "live_postrm_exit_zero" "$rc" "/tmp/live-postrm.log"

uci -q get network.tailscale >/dev/null 2>&1
check_rc_nonzero "live_postrm_host_network_section_removed" "$?"

uci -q get firewall.tailscale_zone >/dev/null 2>&1
check_rc_nonzero "live_postrm_host_firewall_zone_removed" "$?"

# M5: all 4 killswitch firewall sections must be gone, not just 3.
for _sec in lan_to_wan_block block_wan_dns allow_ts_dns allow_ts_traffic; do
    uci -q get "firewall.${_sec}" >/dev/null 2>&1
    check_rc_nonzero "live_postrm_killswitch_${_sec}_removed" "$?"
done

CALLS=$(sentinel_calls)
check_contains "live_postrm_network_reload_called" "network reload" "$CALLS"
check_contains "live_postrm_firewall_reload_called" "firewall reload" "$CALLS"

# =====================================================================
# Scenario 7: LIVE -- tailscale-killswitch.sh's DNS backup must survive a
# double-enable (C3 finding). configure_router_dns backed up
# dhcp.@dnsmasq[0].server UNCONDITIONALLY, unlike apply_rules' boot-time
# guard (`[ ! -f "$DNS_BACKUP_FILE" ]`) -- so calling `enable` twice without
# an intervening `disable` re-captures the ALREADY-REDIRECTED MagicDNS
# addresses as "the originals", and a later `disable` restores DNS to those
# dead addresses instead of the router's real original servers.
# =====================================================================
reset_sentinel
rm -f /etc/tailscale/dns_backup
mkdir -p /etc/tailscale

# Fresh firewall zone (scenario 6's postrm deleted it) so verify_zone passes.
uci set firewall.tailscale_zone=zone

# Seed a real pre-existing dnsmasq section + a real multi-value DNS server
# list -- the "original" configuration a real router would have before the
# killswitch ever touched it.
uci set dhcp.cfg_dns=dnsmasq
uci add_list "dhcp.@dnsmasq[0].server=8.8.8.8"
uci add_list "dhcp.@dnsmasq[0].server=1.1.1.1"
ORIGINAL_DNS=$(printf '8.8.8.8\n1.1.1.1')

sh "$SRC/tailscale-killswitch.sh" enable >/tmp/killswitch-enable1.log 2>&1
rc=$?
check_rc_zero "live_killswitch_enable1_exit_zero" "$rc" "/tmp/killswitch-enable1.log"

BACKUP_AFTER_1=$(cat /etc/tailscale/dns_backup 2>/dev/null || echo "(missing)")
check_eq "live_killswitch_backup_after_first_enable_is_original" "$ORIGINAL_DNS" "$BACKUP_AFTER_1"

# Double-enable: without the C3 guard, this re-backs-up the CURRENT
# (already MagicDNS-redirected) server list, clobbering the true original.
sh "$SRC/tailscale-killswitch.sh" enable >/tmp/killswitch-enable2.log 2>&1
rc=$?
check_rc_zero "live_killswitch_enable2_exit_zero" "$rc" "/tmp/killswitch-enable2.log"

BACKUP_AFTER_2=$(cat /etc/tailscale/dns_backup 2>/dev/null || echo "(missing)")
check_eq "live_killswitch_backup_after_double_enable_still_original" "$ORIGINAL_DNS" "$BACKUP_AFTER_2"

sh "$SRC/tailscale-killswitch.sh" disable >/tmp/killswitch-disable.log 2>&1
rc=$?
check_rc_zero "live_killswitch_disable_exit_zero" "$rc" "/tmp/killswitch-disable.log"

RESTORED=$(uci -q get "dhcp.@dnsmasq[0].server" 2>/dev/null)
check_eq "live_killswitch_disable_restores_original_dns_not_magicdns" "$ORIGINAL_DNS" "$RESTORED"

uci -q get "dhcp.@dnsmasq[0].noresolv" >/dev/null 2>&1
check_rc_nonzero "live_killswitch_disable_clears_noresolv" "$?"

if [ -f /etc/tailscale/dns_backup ]; then rc=0; else rc=1; fi
check_rc_nonzero "live_killswitch_disable_removes_backup_file" "$rc"

# =====================================================================
# Scenario 8: LIVE -- tailscale.init's first-boot re-derivation must also
# cover has_wwan (H5 finding), mirroring how mem_limit/gogc/no_logs are
# already re-derived when postinst deferred hardware detection under an
# install-root bake.
# =====================================================================
reset_sentinel

# Minimal OpenWrt shell-library stand-ins for what tailscale.init's
# start_service calls (config_load/config_get/config_get_bool normally come
# from /lib/functions.sh, procd_* from procd's shell helpers) -- neither
# exists in this generic alpine container.
#
# config_load/config_get/config_get_bool reproduce real /lib/functions.sh
# SNAPSHOT semantics, not a live uci proxy: config_load copies the on-disk
# uci-stub store for the named package into CONFIG_SNAPSHOT at that exact
# moment, and config_get/config_get_bool read only that snapshot. A `uci
# set`/`uci commit` that happens AFTER config_load (e.g. tailscale.init's
# own first-boot hardware re-derivation inside start_service) therefore
# stays invisible to config_get until the NEXT config_load call -- exactly
# like real OpenWrt. A live uci proxy here would silently paper over that
# staleness bug (H_STALE finding) instead of catching it.
#
# procd_set_param/procd_append_param log every call to PROCD_CALLS instead
# of being pure no-ops, so a scenario can assert on exactly what
# command-line/env params start_service handed procd on a given run (e.g.
# "did the derived GOMEMLIMIT/GOGC/no-logs actually apply on THIS first
# start", not just "did the UCI write happen somewhere").
CONFIG_SNAPSHOT=/tmp/config-snapshot
PROCD_CALLS=/tmp/procd-calls

config_load() {
    cp "/etc/config/$1" "$CONFIG_SNAPSHOT" 2>/dev/null || : > "$CONFIG_SNAPSHOT"
}
config_get() {
    _cg_var="$1"; _cg_section="$2"; _cg_option="$3"; _cg_default="${4:-}"
    _cg_val=$(awk -F '\t' -v s="$_cg_section" -v k="$_cg_option" '
        $1 == "O" && $2 == s && $3 == k { v = $4; f = 1 }
        END { if (f) print v }
    ' "$CONFIG_SNAPSHOT" 2>/dev/null)
    [ -z "$_cg_val" ] && _cg_val="$_cg_default"
    eval "$_cg_var=\"\$_cg_val\""
}
config_get_bool() {
    _cgb_var="$1"; _cgb_section="$2"; _cgb_option="$3"; _cgb_default="${4:-0}"
    _cgb_val=$(awk -F '\t' -v s="$_cgb_section" -v k="$_cgb_option" '
        $1 == "O" && $2 == s && $3 == k { v = $4; f = 1 }
        END { if (f) print v }
    ' "$CONFIG_SNAPSHOT" 2>/dev/null)
    [ -z "$_cgb_val" ] && _cgb_val="$_cgb_default"
    eval "$_cgb_var=\"\$_cgb_val\""
}
procd_open_instance() { :; }
procd_set_param() { echo "procd_set_param $*" >> "$PROCD_CALLS"; }
procd_append_param() { echo "procd_append_param $*" >> "$PROCD_CALLS"; }
procd_close_instance() { :; }

# awk is shadowed (not tailscale.init's /proc/meminfo path) so a scenario
# can force start_service's RAM-tier branch deterministically instead of
# depending on this container's real (and irrelevant) memory size -- only
# the exact MemTotal invocation is intercepted when FAKE_MEMTOTAL_MB is
# set; every other awk call (including config_get/config_get_bool's above)
# falls through untouched to the real binary via `command awk`.
awk() {
    case "$*" in
        *MemTotal*)
            if [ -n "${FAKE_MEMTOTAL_MB:-}" ]; then
                echo "$FAKE_MEMTOTAL_MB"
                return 0
            fi
            ;;
    esac
    command awk "$@"
}

# shellcheck source=/dev/null
. "$SRC/tailscale.init"

# Reset to a clean, pristine tailscale package config: enabled (so
# start_service doesn't return early on its enabled-gate) but hardware
# detection never having run -- has_wwan and detected both absent, exactly
# the state a freshly baked image's first real boot starts from.
seed_enabled_tailscale_config /etc/config

HAS_WWAN_BEFORE=$(uci -q get tailscale.hardware.has_wwan 2>/dev/null || echo "(unset)")
check_eq "live_init_has_wwan_unset_before_first_boot" "(unset)" "$HAS_WWAN_BEFORE"

start_service

HAS_WWAN_AFTER=$(uci -q get tailscale.hardware.has_wwan 2>/dev/null || echo "(unset)")
case "$HAS_WWAN_AFTER" in
    0|1) pass "live_init_has_wwan_derived_at_first_boot" ;;
    *) fail "live_init_has_wwan_derived_at_first_boot" "expected 0 or 1, got '$HAS_WWAN_AFTER'" ;;
esac

DETECTED_AFTER=$(uci -q get tailscale.hardware.detected 2>/dev/null || echo "(unset)")
check_eq "live_init_detected_marked_after_first_boot" "1" "$DETECTED_AFTER"

# =====================================================================
# Scenario 9: LIVE -- tailscale.init's first-boot re-derivation must APPLY
# the derived gogc/no_logs to procd on this SAME first start, not just
# persist them to disk for uci to serve on a later boot (H_STALE finding:
# config_get right after `uci commit` reads the config_load-time snapshot
# per real /lib/functions.sh semantics, not disk -- so re-reading via
# config_get immediately after the commit silently keeps the stale
# pre-detection ""/""/0 values for the rest of THIS run, meaning a low-RAM
# device's very first start runs tailscaled unconstrained and verbose,
# exactly the device this feature exists to protect, until a later reboot).
#
# Regression guard (docs/gomemlimit-field-report.md): GOMEMLIMIT must NOT
# reach procd's env at all, on this or any tier -- field testing found it
# breaks tailscaled's data path on low-RAM devices (disco/ping stay up, TCP
# to local services over the tunnel silently drops) even though mem_limit
# is still derived/persisted to UCI above. GOGC is the only tuning knob
# that may reach procd. This assertion is intentionally inverted from its
# original form (which asserted GOMEMLIMIT=50MiB WAS applied) -- it must go
# RED against the pre-fix tailscale.init (which still applied GOMEMLIMIT)
# and GREEN after.
# =====================================================================
reset_sentinel
: > "$PROCD_CALLS"
seed_enabled_tailscale_config /etc/config

FAKE_MEMTOTAL_MB=64 start_service

PROCD_LOG=$(cat "$PROCD_CALLS" 2>/dev/null || true)
check_not_contains "live_init_low_ram_gomemlimit_not_applied_on_first_boot" "GOMEMLIMIT" "$PROCD_LOG"
check_contains "live_init_low_ram_gogc_applied_on_first_boot" "env GOGC=50" "$PROCD_LOG"
check_contains "live_init_low_ram_no_logs_applied_on_first_boot" "no-logs-no-support" "$PROCD_LOG"

exit 0
