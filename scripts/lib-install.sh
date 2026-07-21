#!/bin/sh
# scripts/lib-install.sh
#
# Shared install-time primitives (RFC docs/rfc-apk-builds.md §4.4, slice
# D1). Before this slice, install-glinet.sh entangled a handful of
# genuinely reusable helpers -- colored log_*, /dev/tty prompt reads,
# arch detection, and a service-startup poll loop -- with GL.iNet-specific
# mechanics (binary download/swap, gl_tailscale restart) inside the SAME
# functions. Adding a second entry point (scripts/install.sh, for the
# apk/ipk paths) by copy-pasting those fixes would reproduce exactly the
# "three divergent scripts" problem the RFC calls out for arches.json
# (§4.5) and warns against here too -- so this file is the ONE authored
# copy of each primitive, sourced by every install-time script instead.
#
# Primitives:
#   log_info / log_warn / log_error   -- colored (when stdout is a tty),
#                                         plain otherwise; write to stderr
#                                         so they never pollute a caller's
#                                         captured stdout.
#   detect_arch                       -- `uname -m` -> one of this repo's
#                                         four arches.json names, or a
#                                         loud unsupported-arch error.
#   detect_release                    -- reads DISTRIB_RELEASE out of
#                                         /etc/openwrt_release. NEW code
#                                         (not carried forward from
#                                         install-glinet.sh, which never
#                                         needed release detection -- it
#                                         only ever targets GL.iNet 4.x).
#                                         Prints the release string and
#                                         returns 0 on success; prints
#                                         NOTHING and returns 1 if the file
#                                         is missing or doesn't define
#                                         DISTRIB_RELEASE -- callers must
#                                         treat that as "unknown", never
#                                         silently assume a path.
#   prompt_confirm question [default] -- the /dev/tty fix carried forward
#                                         from install-glinet.sh's recent
#                                         commits (b3ac95d, 943b911): a
#                                         plain `read` during
#                                         `curl ... | sh` reads from the
#                                         piped SCRIPT, not the user, so
#                                         every confirmation prompt must
#                                         read from the controlling
#                                         terminal explicitly.
#   AUTO_YES / should_reinstall()     -- the shared non-interactive escape
#                                         hatch (M9 fix). Originally lived
#                                         only in install.sh (gating its own
#                                         ipk/apk paths' reinstall prompt);
#                                         promoted here so install-glinet.sh
#                                         shares the SAME convention instead
#                                         of its own separate inline
#                                         "Reinstall anyway?" prompt with no
#                                         -y equivalent -- a -y/--yes on any
#                                         of the three paths (including via
#                                         install.sh's dispatcher forwarding
#                                         -y into glinet_path()) now means
#                                         the same thing everywhere. Each
#                                         script still owns its own argv
#                                         parsing; this is only the shared
#                                         decision, not shared flag parsing --
#                                         callers set AUTO_YES=true from
#                                         their own -y/--yes handling before
#                                         calling should_reinstall().
#   poll_for_service name timeout     -- the service-startup poll carried
#                                         forward from install-glinet.sh's
#                                         recent commits (8a2d260,
#                                         b3ac95d): UPX-compressed
#                                         tailscaled can take a few seconds
#                                         to decompress and register with
#                                         procd on first start, so a
#                                         same-instant `pgrep` check is
#                                         flaky. Polls once a second up to
#                                         <timeout>, printing progress
#                                         dots to stderr.
#   get_latest_version repo           -- resolves the latest GitHub
#                                         release tag (strips a leading
#                                         "v"). Reused by both the ipk and
#                                         glinet paths (both download a
#                                         versioned release asset by
#                                         filename); the apk path doesn't
#                                         need it (feed-based, no version
#                                         string in the URL).
#   opkg_tracked_tailscale             -- ipk/apk coexistence detection
#   clean_opkg_tailscale                  (RFC docs/rfc-apk-builds.md
#                                         §4.1/§4.7, slice D3). See the
#                                         block below the primitives above
#                                         for the full rationale; used by
#                                         install.sh's apk_path() as a
#                                         preflight BEFORE the apk install
#                                         proceeds.
#
# POSIX sh only. Source, don't execute:
#   . "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib-install.sh"

# --- colors (only if stdout is a terminal) ---------------------------------
if [ -t 1 ]; then
    LIB_INSTALL_RED='\033[0;31m'
    LIB_INSTALL_GREEN='\033[0;32m'
    LIB_INSTALL_YELLOW='\033[1;33m'
    LIB_INSTALL_NC='\033[0m'
else
    LIB_INSTALL_RED=''
    LIB_INSTALL_GREEN=''
    LIB_INSTALL_YELLOW=''
    LIB_INSTALL_NC=''
fi

log_info() { printf "${LIB_INSTALL_GREEN}[INFO]${LIB_INSTALL_NC} %s\n" "$1" >&2; }
log_warn() { printf "${LIB_INSTALL_YELLOW}[WARN]${LIB_INSTALL_NC} %s\n" "$1" >&2; }
log_error() { printf "${LIB_INSTALL_RED}[ERROR]${LIB_INSTALL_NC} %s\n" "$1" >&2; }

# --- pinned usign public key for verifying CI-signed release artifacts ----
# (round-3 FIX4 promotion) CI signs every .ipk via imprimatur's
# `/sign/usign` (Ed-prefixed usign format, key-id 260114ce974e57e5) and
# attaches the resulting `<pkg>.ipk.sig` to the GitHub Release -- install.sh's
# ipk_path() verifies that BEFORE opkg ever sees the file (see install.sh's
# own H1 comment). CI now ALSO usign-signs the release's loose SHA256SUMS
# file the same way, attaching a detached SHA256SUMS.sig (CI/workflow side
# of this contract, tracked separately) -- install-glinet.sh's
# download_binary() verifies THAT signature before trusting SHA256SUMS's
# hashes to check the raw tailscaled binary, giving the GL.iNet path the
# same cryptographic root as the ipk path instead of checking a binary's
# hash against a checksum file fetched from the same untrusted release host
# it's meant to help verify.
#
# Previously this constant was defined only in install.sh; promoted here so
# there is exactly ONE copy shared by both scripts instead of two that could
# silently drift -- byte-for-byte the same content as the git-tracked
# repo-root file `signing.pub` (verified key-id 260114ce974e57e5 -- `Ed` +
# SHA512-derived 8-byte id, per usign's own pubkey format).
TAILSCALE_USIGN_PUBKEY='untrusted comment: tailscale-openwrt signing key
RWQmARTOl05X5S4qvwV9kl21YqbWx7/y1fQqHVWFolGsccolt39ey8HT'

# sha256_verify <file> <expected_hex> -- verifies <file>'s whole-file sha256
# hex digest equals <expected_hex>. Fails closed (returns 1, no output) if
# 'sha256sum' is missing, <file> doesn't exist/isn't readable, or the
# digests don't match; returns 0 only on an exact match. Pure: no exit, no
# global state.
#
# Round-3 dedup (FIX2, round-2 review): install-glinet.sh's SHA256SUMS-based
# binary check and install.sh's apk feed-key pin compare each independently
# implemented "compute sha256, compare to an expected value, fail closed" --
# the same primitive, written twice. This is the ONE shared copy; both call
# sites route their actual gating decision through it instead of
# reimplementing the compare (see install.sh's apk_path() and
# install-glinet.sh's download_binary()). Deliberately separate from the
# usign asymmetric-signature checks (H1/FIX4 above) -- those are a
# genuinely different verification (public-key signature, not a
# pre-shared/pinned digest), not a candidate for this dedup.
sha256_verify() {
    _sv_file="$1"
    _sv_expected="$2"
    if ! command -v sha256sum >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -f "${_sv_file}" ]; then
        return 1
    fi
    _sv_actual=$(sha256sum "${_sv_file}" | awk '{print $1}')
    [ "${_sv_actual}" = "${_sv_expected}" ]
}

# detect_arch -- prints one of this repo's arches.json names on stdout, or
# a loud error + exit 1 for anything unrecognized. Logic carried forward
# byte-for-byte from install-glinet.sh (it already handled all four arches
# this repo ships).
detect_arch() {
    _machine=$(uname -m)
    case "${_machine}" in
        aarch64)
            echo "aarch64_cortex-a53"
            ;;
        armv7l)
            echo "arm_cortex-a7"
            ;;
        mips)
            echo "mips_24kc"
            ;;
        mipsel)
            echo "mipsel_24kc"
            ;;
        *)
            log_error "Unsupported architecture: ${_machine}"
            log_error "Supported: aarch64, armv7l, mips, mipsel"
            exit 1
            ;;
    esac
}

# detect_release -- prints $DISTRIB_RELEASE from /etc/openwrt_release on
# stdout and returns 0. Returns 1 (prints nothing) if the file is missing
# or malformed (doesn't define DISTRIB_RELEASE) -- this is the failure
# path the RFC calls out as needing its own handling/test: a caller MUST
# NOT default to any particular install path on a detect_release failure
# without an explicit, visible decision (see install.sh's dispatcher).
# OPENWRT_RELEASE_FILE overrides the path (default /etc/openwrt_release) --
# same test-overridable-env-var convention as this repo's other scripts
# (ROOTFS_CACHE_DIR, IMPRIMATUR_REPO_DIR, etc), so
# tests/apk/install-dispatch.sh can exercise both the found and
# missing/malformed cases against a fixture file, no root/real device
# needed.
detect_release() {
    _rel_file="${OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
    if [ ! -f "${_rel_file}" ]; then
        return 1
    fi
    DISTRIB_RELEASE=""
    # shellcheck disable=SC1090
    if ! . "${_rel_file}" 2>/dev/null; then
        return 1
    fi
    if [ -z "${DISTRIB_RELEASE}" ]; then
        return 1
    fi
    echo "${DISTRIB_RELEASE}"
    return 0
}

# prompt_confirm "question text" [default: y|n, default "n"]
# Reads a single line from /dev/tty (NEVER stdin -- the carried-forward
# fix). Returns 0 for an affirmative answer, 1 otherwise. An empty
# response (bare enter) takes the default. If /dev/tty can't be opened at
# all (e.g. fully detached/non-interactive automation), treats that as an
# empty response too, so the default still governs rather than hanging or
# erroring -- callers that need a hard non-interactive mode should avoid
# calling prompt_confirm in the first place (see install.sh's -y/--yes).
prompt_confirm() {
    _question="$1"
    _default="${2:-n}"
    case "${_default}" in
        y|Y) _hint="[Y/n]" ;;
        *) _hint="[y/N]" ;;
    esac
    printf '%s %s ' "${_question}" "${_hint}" >&2
    if ! read -r _response </dev/tty 2>/dev/null; then
        _response=""
    fi
    if [ -z "${_response}" ]; then
        _response="${_default}"
    fi
    case "${_response}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# AUTO_YES / should_reinstall -- see the header comment above (M9). Default
# to "false" only if a caller hasn't already set it (e.g. install.sh's own
# -y/--yes argv parsing runs AFTER this file is sourced and simply assigns
# AUTO_YES=true directly -- this default just covers "never set at all").
#
# ROUND-3 FIX: the prompt's default answer is "n", NOT "y". install-glinet.sh's
# ORIGINAL inline "Reinstall anyway?" prompt (pre-M9) defaulted to N -- a bare
# Enter, or any non-interactive run where /dev/tty can't be opened at all
# (prompt_confirm treats that the same as an empty response), left the
# existing install untouched. M9's job was only to propagate -y/AUTO_YES as a
# shared escape hatch across all three paths; it must NOT also flip the
# prompt's own default. A "y" default here would mean a non-interactive
# re-run WITHOUT -y (cron, a detached/no-tty session) REINSTALLS and restarts
# tailscaled by default -- unattended disruption of a running VPN service.
# The safe no-op (leave the existing install alone) must be the default
# everywhere; only an explicit "y" answer or -y/AUTO_YES proceeds.
AUTO_YES="${AUTO_YES:-false}"
should_reinstall() {
    if [ "${AUTO_YES}" = "true" ]; then
        return 0
    fi
    prompt_confirm "Reinstall/upgrade anyway?" n
}

# poll_for_service <process_name> <timeout_seconds>
# Polls `pgrep -x <process_name>` once a second until it's seen or
# <timeout_seconds> elapses. Returns 0 if seen, 1 on timeout. Prints
# progress dots to stderr (matches install-glinet.sh's prior inline
# behavior byte-for-byte, now reusable by the apk/ipk paths too).
poll_for_service() {
    _svc_name="$1"
    _svc_timeout="$2"
    _svc_i=0
    printf 'Waiting for %s to start' "${_svc_name}" >&2
    while [ "${_svc_i}" -lt "${_svc_timeout}" ]; do
        if pgrep -x "${_svc_name}" >/dev/null 2>&1; then
            printf '\n' >&2
            echo "Service status:" >&2
            echo "  ${_svc_name} is running" >&2
            return 0
        fi
        printf '.' >&2
        sleep 1
        _svc_i=$((_svc_i + 1))
    done
    printf '\n' >&2
    echo "Service status:" >&2
    echo "  ${_svc_name} is not running (may still be starting)" >&2
    return 1
}

# get_latest_version <owner/repo> -- resolves the latest GitHub release
# tag via the public API, strips a leading "v". Prints nothing and
# returns 1 on failure (never silently prints an empty version).
get_latest_version() {
    _gv_repo="$1"
    _gv_version=$(wget -qO- "https://api.github.com/repos/${_gv_repo}/releases/latest" 2>/dev/null | \
        grep -o '"tag_name": *"[^"]*"' | \
        sed 's/"tag_name": *"//;s/"//;s/^v//')
    if [ -z "${_gv_version}" ]; then
        return 1
    fi
    echo "${_gv_version}"
    return 0
}

# --- ipk -> apk coexistence: filesystem-level opkg detection + cleanup ----
# (RFC docs/rfc-apk-builds.md §4.1/§4.7, slice D3)
#
# apk and opkg are DISJOINT package databases -- apk literally cannot see
# an opkg-tracked install (§4.1). So on the 24.10 -> 25.12 upgrade path, if
# a sysupgrade preserves /etc (and the rest of a stale ipk-installed
# tailscale's footprint) into a 25.12 apk-only rootfs, `apk add tailscale`
# has NO WAY to know an old install already owns
# usr/sbin/tailscaled/etc/init.d/tailscale/etc/config/tailscale and the
# network/firewall UCI state its postinst created -- it just lays its own
# copy on top. Left alone, this produces exactly the two failure modes the
# RFC calls out: the system stays dual-registered (opkg's own package
# database still lists a "tailscale" it can never coherently
# upgrade/remove again once apk also owns those paths), and any state only
# an ipk postrm would have cleaned up (the killswitch DNS backup/redirect
# is the concrete example -- see tailscale.postrm) is orphaned forever,
# since nothing ever runs that opkg postrm.
#
# Detection is therefore FILESYSTEM/opkg-DB-level only, never apk
# `replaces:`/`conflicts:` metadata -- apk has nothing to compare that
# metadata against in the first place. The opkg package database itself is
# just files on disk (no daemon involved): each installed package gets
# /usr/lib/opkg/info/<pkg>.{control,list,conffiles,postinst,prerm,postrm}
# (whichever of the maintainer scripts it shipped) plus a stanza in
# /usr/lib/opkg/status. Both survive an in-place sysupgrade that preserves
# /etc and other persistent paths, independent of whether the `opkg`
# *binary* itself does (empirically, OpenWrt 25.12's own rootfs ships no
# opkg at all -- apk-only -- so on a real device the manual-cleanup branch
# below, not the `opkg remove` branch, is the one that actually fires).
#
# OPKG_INFO_DIR / OPKG_STATUS_FILE (default /usr/lib/opkg/info,
# /usr/lib/opkg/status) are overridable for the same reason
# OPENWRT_RELEASE_FILE is: so tests/apk/upgrade-downgrade.sh can point
# this at a fixture tree instead of the real system.

# opkg_tracked_tailscale -- returns 0 if a "tailscale" install is tracked
# by opkg, 1 otherwise. Prefers the filesystem marker (works whether or
# not the opkg binary itself is present); falls back to `opkg
# list-installed` when opkg IS on PATH, for the (unlikely on 25.12, but
# not the point being asserted here) case where the info dir was somehow
# tampered with/incomplete but opkg's own status file still knows about
# the package.
opkg_tracked_tailscale() {
    _otc_info_dir="${OPKG_INFO_DIR:-/usr/lib/opkg/info}"
    if [ -f "${_otc_info_dir}/tailscale.control" ]; then
        return 0
    fi
    if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -q '^tailscale '; then
        return 0
    fi
    return 1
}

# clean_opkg_tailscale -- removes a stale opkg-tracked "tailscale" install
# BEFORE the apk path lays its own copy down. Two branches:
#   - `opkg` on PATH: let opkg do it for real (`opkg remove tailscale`),
#     the same as a device that still ships opkg alongside apk would need.
#   - `opkg` NOT on PATH (the real 25.12 case, confirmed empirically --
#     apk-only rootfs): the opkg binary is gone but its bookkeeping files
#     can still be sitting there from before the sysupgrade, so this runs
#     the SAME recorded prerm/postrm scripts directly (they're just shell
#     scripts, sitting right there in the info dir) and then removes the
#     payload files they listed (skipping conffiles, same rule opkg itself
#     applies) and the bookkeeping files/status stanza. This is the
#     "documented manual removal" the RFC calls out as the alternative to
#     a live `opkg remove`.
clean_opkg_tailscale() {
    _cot_info_dir="${OPKG_INFO_DIR:-/usr/lib/opkg/info}"
    _cot_status_file="${OPKG_STATUS_FILE:-/usr/lib/opkg/status}"

    log_warn "Detected a stale opkg-tracked 'tailscale' install (ipk -> apk transition)."
    log_warn "apk cannot see the opkg package database, so this must be cleaned up before the apk install proceeds (RFC docs/rfc-apk-builds.md section 4.1/4.7)."

    if command -v opkg >/dev/null 2>&1; then
        log_info "Running 'opkg remove tailscale' to clean up the old install (runs its postrm)..."
        if opkg remove tailscale; then
            log_info "Old opkg-tracked install removed"
            return 0
        fi
        log_warn "'opkg remove tailscale' failed -- falling back to manual cleanup"
    else
        log_info "'opkg' is not on PATH (OpenWrt 25.12+ ships apk only) -- cleaning up the leftover opkg-tracked footprint manually"
    fi

    _clean_opkg_tailscale_manual "${_cot_info_dir}" "${_cot_status_file}"
}

# _clean_opkg_tailscale_manual info_dir status_file -- the manual-removal
# branch: run the recorded prerm, delete the recorded payload files (never
# the recorded conffiles), run the recorded postrm, then remove opkg's own
# bookkeeping (info files + status stanza) for the package. Every step is
# best-effort (a missing/already-gone piece is not an error) -- the goal is
# "leave nothing dual-tracked", not "fail loudly if the footprint was
# already partial".
_clean_opkg_tailscale_manual() {
    _com_dir="$1"
    _com_status="$2"

    if [ -x "${_com_dir}/tailscale.prerm" ]; then
        log_info "Running the recorded opkg prerm (stops the old service)..."
        "${_com_dir}/tailscale.prerm" || log_warn "tailscale.prerm exited non-zero (continuing)"
    fi

    if [ -f "${_com_dir}/tailscale.list" ]; then
        while IFS= read -r _com_f || [ -n "${_com_f}" ]; do
            [ -z "${_com_f}" ] && continue
            if [ -f "${_com_dir}/tailscale.conffiles" ] && grep -qxF "${_com_f}" "${_com_dir}/tailscale.conffiles"; then
                continue
            fi
            [ -f "${_com_f}" ] && rm -f "${_com_f}"
        done < "${_com_dir}/tailscale.list"
    fi

    if [ -x "${_com_dir}/tailscale.postrm" ]; then
        log_info "Running the recorded opkg postrm (cleans firewall/uci/DNS state)..."
        "${_com_dir}/tailscale.postrm" || log_warn "tailscale.postrm exited non-zero (continuing)"
    fi

    rm -f "${_com_dir}"/tailscale.control "${_com_dir}"/tailscale.list \
        "${_com_dir}"/tailscale.conffiles "${_com_dir}"/tailscale.postinst \
        "${_com_dir}"/tailscale.prerm "${_com_dir}"/tailscale.postrm

    if [ -f "${_com_status}" ]; then
        awk 'BEGIN{RS="";ORS="\n\n"} $0 !~ /(^|\n)Package: tailscale(\n|$)/' "${_com_status}" > "${_com_status}.new" 2>/dev/null \
            && mv "${_com_status}.new" "${_com_status}"
    fi

    log_info "Manual opkg-tracked cleanup complete"
}
