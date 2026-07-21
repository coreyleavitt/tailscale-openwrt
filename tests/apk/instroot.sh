#!/bin/sh
# tests/apk/instroot.sh
#
# Slice A3a test (RFC docs/rfc-apk-builds.md §4.1's O1 finding): the
# tailscale.{postinst,prerm,postrm} maintainer scripts are not chrooted by
# apk/opkg during an offline/install-root (e.g. ImageBuilder bake) install
# -- they run against the build host's real filesystem unless they redirect
# themselves via $IPKG_INSTROOT. Verifies the three-category guard:
#   1. root-relative persistent state (uci config, the rc.d enable symlink)
#      is REDIRECTED under $IPKG_INSTROOT, not skipped;
#   2. live-system actions (service reload/enable/start/stop) are NO-OP'd
#      under a non-empty root;
#   3. IPKG_INSTROOT empty/unset (a normal live install) is byte-equivalent
#      in effect to before the guard.
#
# All three maintainer scripts run inside a disposable `alpine` container
# (tests/apk/fixtures/instroot-driver.sh, with a stubbed uci/logger on
# PATH and sentinel /etc/init.d/* scripts standing in for the live system)
# -- `--rm`, nothing is ever run against the real host. See
# tests/apk/fixtures/uci-stub for exactly what subset of uci(1) it
# reimplements and why a stub is used instead of a real (foreign-arch)
# uci binary.
#
# Uses the shared tests/apk/lib.sh harness (established slice A2).
#
# Also covers three verified code-review findings that reuse this same
# disposable-container harness rather than standing up a separate one:
#   - C3: tailscale-killswitch.sh's DNS backup must survive a double-enable
#     without an intervening disable (it must not re-capture the
#     already-redirected MagicDNS addresses as "the original" DNS).
#   - H5: tailscale.postinst's has_wwan detection must be deferred under an
#     install-root bake (like mem_limit/gogc) and re-derived by
#     tailscale.init at first real boot.
#   - M5: tailscale.postrm must remove all 4 killswitch firewall sections
#     (including allow_ts_traffic, created by tailscale-killswitch.sh, not
#     postinst), not just 3.
#
# Usage: sh tests/apk/instroot.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_SRC="${REPO_ROOT}/tailscale-package/src"
FIXTURES="${SCRIPT_DIR}/fixtures"
IMAGE="${INSTROOT_TEST_IMAGE:-alpine:3.20}"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker

for f in tailscale.postinst tailscale.prerm tailscale.postrm tailscale-killswitch.sh tailscale.init; do
    if [ ! -f "${PKG_SRC}/${f}" ]; then
        echo "FAIL: ${PKG_SRC}/${f} not found" >&2
        exit 1
    fi
done

chmod +x "${FIXTURES}/uci-stub" "${FIXTURES}/logger-stub" "${FIXTURES}/instroot-driver.sh"

OUTPUT=$(docker run --rm \
    -v "${PKG_SRC}:/src:ro" \
    -v "${FIXTURES}/uci-stub:/fixtures/bin/uci:ro" \
    -v "${FIXTURES}/logger-stub:/fixtures/bin/logger:ro" \
    -v "${FIXTURES}/instroot-driver.sh:/driver.sh:ro" \
    "${IMAGE}" sh /driver.sh 2>&1) || {
    echo "FAIL: instroot-driver.sh container exited non-zero" >&2
    echo "${OUTPUT}"
    exit 1
}

echo "${OUTPUT}"

# Every expected CHECK name that must appear, so a driver-side bug that
# silently skips a scenario (e.g. an early `exit` before some checks run)
# is itself a failure, not just a smaller-than-expected pass count.
EXPECTED_CHECKS="
bake_postinst_exit_zero
bake_postinst_host_network_untouched
bake_postinst_host_firewall_untouched
bake_postinst_host_rcd_symlink_absent
bake_postinst_host_statedir_absent
bake_postinst_no_service_reload_or_start
bake_postinst_instroot_network_section_type
bake_postinst_instroot_network_proto
bake_postinst_instroot_network_device
bake_postinst_instroot_firewall_zone_type
bake_postinst_instroot_killswitch_include_type
bake_postinst_instroot_killswitch_include_path
bake_postinst_instroot_rcd_start_symlink_exists
bake_postinst_instroot_rcd_stop_symlink_exists
bake_postinst_instroot_rcd_symlink_target
bake_postinst_instroot_statedir_created
bake_postinst_instroot_has_wwan_absent
bake_postrm_exit_zero
bake_postrm_instroot_network_section_removed
bake_postrm_instroot_firewall_zone_removed
bake_postrm_instroot_rcd_start_symlink_removed
bake_postrm_instroot_rcd_stop_symlink_removed
bake_postrm_instroot_killswitch_lan_to_wan_block_removed
bake_postrm_instroot_killswitch_block_wan_dns_removed
bake_postrm_instroot_killswitch_allow_ts_dns_removed
bake_postrm_instroot_killswitch_allow_ts_traffic_removed
bake_postrm_host_network_still_untouched
bake_postrm_no_service_reload
bake_prerm_exit_zero
bake_prerm_no_service_stop
live_postinst_exit_zero
live_postinst_host_network_section_type
live_postinst_host_network_proto
live_postinst_host_firewall_zone_type
live_postinst_host_killswitch_include_type
live_postinst_host_statedir_created
live_postinst_network_reload_called
live_postinst_firewall_reload_called
live_postinst_service_enable_called
live_postinst_service_start_called
live_prerm_exit_zero
live_prerm_service_stop_called
live_postrm_exit_zero
live_postrm_host_network_section_removed
live_postrm_host_firewall_zone_removed
live_postrm_killswitch_lan_to_wan_block_removed
live_postrm_killswitch_block_wan_dns_removed
live_postrm_killswitch_allow_ts_dns_removed
live_postrm_killswitch_allow_ts_traffic_removed
live_postrm_network_reload_called
live_postrm_firewall_reload_called
live_killswitch_enable1_exit_zero
live_killswitch_backup_after_first_enable_is_original
live_killswitch_enable2_exit_zero
live_killswitch_backup_after_double_enable_still_original
live_killswitch_disable_exit_zero
live_killswitch_disable_restores_original_dns_not_magicdns
live_killswitch_disable_clears_noresolv
live_killswitch_disable_removes_backup_file
live_init_has_wwan_unset_before_first_boot
live_init_has_wwan_derived_at_first_boot
live_init_detected_marked_after_first_boot
live_init_low_ram_gomemlimit_not_applied_on_first_boot
live_init_low_ram_gogc_applied_on_first_boot
live_init_low_ram_no_logs_applied_on_first_boot
"

for name in ${EXPECTED_CHECKS}; do
    line=$(echo "${OUTPUT}" | grep -E "^CHECK ${name} (PASS|FAIL)" || true)
    if [ -z "${line}" ]; then
        log_fail "expected CHECK '${name}' did not run at all"
        continue
    fi
    case "${line}" in
        *" PASS"*) log_info "OK: ${name}" ;;
        *) log_fail "${line#CHECK ${name} FAIL }" ;;
    esac
done

harness_finish "tests/apk/instroot.sh"
