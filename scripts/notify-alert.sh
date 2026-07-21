#!/bin/sh
# scripts/notify-alert.sh
#
# Single, shared "make this failure LOUD" primitive (RFC docs/rfc-apk-builds.md
# §1 guiding constraint #2, §4.6 slice C5). The ~2-month CI outage happened
# because a signing failure was invisible -- imprimatur's /health returned 200
# while every /sign call 503'd, and nothing else was watching. C5 wires three
# independent callers onto this ONE script rather than three copies of
# curl-a-webhook logic: the release workflow's apk-path failure() steps, the
# daily cron's auto-republish self-heal, and the daily cron's synthetic feed
# probe -- so "how do we alert" is answered once, testably, in one place.
#
# Deliberately configurable, never hardcoded (task discipline): the target is
# read from the ALERT_WEBHOOK_URL environment variable (wired from a repo/org
# secret at each call site), never a URL literal in this script or in the
# workflow YAML. A generic POST-a-text-body webhook covers both an ntfy.sh
# topic URL and most other webhook receivers (Slack incoming-webhook, a
# Discord webhook, a custom endpoint) without this script knowing which.
#
# Never a silent no-op: even with ALERT_WEBHOOK_URL unset (not yet
# provisioned, or a local/test run), this script still emits a GitHub Actions
# `::error::` annotation, so the failure is visible in the Actions UI run
# summary and rides GitHub's own default owner-email-on-workflow-failure
# notification (RFC §4.6: "confirm/enable ... GitHub's default owner-email on
# workflow failure, or an explicit ntfy/webhook step"). This script provides
# BOTH -- the annotation is unconditional, the webhook is the explicit,
# opt-in-by-secret upgrade.
#
# A webhook POST failure (target down, bad URL, network blip) is reported as
# a `::warning::` and does NOT change this script's own exit code -- alerting
# infrastructure being flaky must never mask or fail the CALLING step's own
# failure() condition (which is what triggered this script in the first
# place); see the loud-failure discipline note in feed-guard.sh for the same
# "never let a secondary check's own failure hide the primary signal" shape.
#
# Usage:
#   notify-alert.sh <short message> [details text via stdin]
#
# Exit: always 0 (this is a best-effort notifier, not a gate -- the caller's
# own exit code is what actually fails the job/step).
set -eu

CURLERR=$(mktemp)
trap 'rm -f "${CURLERR}"' EXIT

MESSAGE="${1:?usage: notify-alert.sh <message> [details via stdin]}"
DETAILS=""
if [ ! -t 0 ]; then
    DETAILS=$(cat 2>/dev/null || true)
fi

echo "::error::${MESSAGE}"
if [ -n "${DETAILS}" ]; then
    echo "${DETAILS}" >&2
fi

if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    BODY="${MESSAGE}"
    if [ -n "${DETAILS}" ]; then
        BODY="${BODY}
${DETAILS}"
    fi
    if printf '%s' "${BODY}" | curl -fsS -X POST "${ALERT_WEBHOOK_URL}" \
        -H 'Content-Type: text/plain; charset=utf-8' \
        --data-binary @- >/dev/null 2>"${CURLERR}"; then
        echo "notify-alert.sh: webhook notified (${ALERT_WEBHOOK_URL%%\?*})"
    else
        echo "::warning::notify-alert.sh: webhook POST to ALERT_WEBHOOK_URL failed ($(cat "${CURLERR}" 2>/dev/null)) -- alert is still visible via the ::error:: annotation above + GitHub's default owner-email-on-workflow-failure" >&2
    fi
else
    echo "::warning::notify-alert.sh: ALERT_WEBHOOK_URL not set -- relying on the ::error:: annotation above + GitHub's default owner-email-on-workflow-failure (set the ALERT_WEBHOOK_URL secret for an explicit ntfy/webhook alert, RFC §4.6)" >&2
fi

exit 0
