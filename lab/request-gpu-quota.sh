#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# request-gpu-quota.sh - file and track EC2 GPU quota increases.
#
#   ./request-gpu-quota.sh            show current values and pending requests
#   ./request-gpu-quota.sh --file     submit increase requests
#   ./request-gpu-quota.sh --watch    poll every 5 min until approved
#
# Quota codes are looked up by name, never hardcoded. AWS changes them and a
# stale code fails with a message that does not explain itself.
# ---------------------------------------------------------------------------
set -uo pipefail

REGION="${REGION:-us-east-2}"
DESIRED="${DESIRED:-8}"     # 8 vCPU: g4dn.xlarge is 4, leaves room to grow
MATCH="${MATCH:-G and VT}"

# Service Quotas are PER-ACCOUNT. Filing in one account and checking from
# another returns "no records", which reads identically to a denial. That
# ambiguity cost a day, so the account is now checked before anything else.
WORKLOAD_ACCOUNT="${WORKLOAD_ACCOUNT:-}"

MODE="${1:-status}"

hr() { printf '%s\n' "-----------------------------------------------------------"; }

require_account() {
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  if [ -z "$acct" ]; then
    printf '\n  \033[31mno valid credentials.\033[0m run: kkaws\n\n'
    exit 1
  fi
  if [ "$acct" != "$WORKLOAD_ACCOUNT" ]; then
    printf '\n  \033[31mWRONG ACCOUNT: %s\033[0m\n' "$acct"
    printf '  GPU quotas live in the workload account %s.\n' "$WORKLOAD_ACCOUNT"
    printf '  Quotas and their request history are per-account, so this account\n'
    printf '  will report zero quota and no requests no matter what you filed.\n\n'
    printf '  run: kkaws   and select Nameplate Analytics\n\n'
    exit 1
  fi
  printf '  account  %s (Nameplate Analytics)\n' "$acct"
}

lookup() {
  aws service-quotas list-service-quotas \
    --service-code ec2 --region "$REGION" \
    --query "Quotas[?contains(QuotaName,'$MATCH')].[QuotaCode,QuotaName,Value]" \
    --output text 2>/dev/null
}

# Without an explicit --status, the history API can return only currently-open
# requests, so a denial looks identical to "you never filed anything". Query
# each status so a DENIED shows up instead of vanishing.
QUOTA_STATUSES="PENDING CASE_OPENED APPROVED DENIED CASE_CLOSED"

pending() {
  local st
  for st in $QUOTA_STATUSES; do
    aws service-quotas list-requested-service-quota-change-history \
      --service-code ec2 --region "$REGION" --status "$st" \
      --query "RequestedQuotas[?contains(QuotaName,'$MATCH')].[QuotaName,DesiredValue,'$st',Created]" \
      --output text 2>/dev/null
  done
}

# Per-quota history. Catches records the service-wide list misses.
history_for() {
  aws service-quotas list-requested-service-quota-change-history-by-quota \
    --service-code ec2 --quota-code "$1" --region "$REGION" \
    --query "RequestedQuotas[].[DesiredValue,Status,Created,LastUpdated]" \
    --output text 2>/dev/null
}

show_status() {
  echo
  require_account
  echo "GPU quotas in $REGION"
  hr
  local any=0
  while IFS=$'\t' read -r code name value; do
    [ -z "${code:-}" ] && continue
    any=1
    v=${value%%.*}
    if [ "${v:-0}" -ge 4 ] 2>/dev/null; then
      printf '  \033[32mOK  \033[0m %-46s %s vCPU\n' "$name" "$value"
    else
      printf '  \033[31mLOW \033[0m %-46s %s vCPU\n' "$name" "$value"
    fi
    printf '        %s\n' "$code"
  done <<< "$(lookup)"
  [ "$any" -eq 0 ] && echo "  could not read quotas (check credentials and region)"

  echo
  echo "Request history (all statuses)"
  hr
  local p
  p="$(pending)"
  if [ -z "$p" ]; then
    echo "  no request records found"
    echo
    echo "  Per-quota history:"
    while IFS=$'\t' read -r code name value; do
      [ -z "${code:-}" ] && continue
      local h
      h="$(history_for "$code")"
      if [ -z "$h" ]; then
        printf '    %s: no records\n' "$code"
      else
        printf '    %s:\n' "$code"
        printf '      %s\n' "$h"
      fi
    done <<< "$(lookup)"
    echo
    echo "  If a request was filed and no record remains, it was closed or denied."
    echo "  Check the email on the account for an AWS Support notification."
  else
    while IFS=$'\t' read -r name desired status created; do
      [ -z "${name:-}" ] && continue
      printf '  %-46s -> %s  [%s]\n' "$name" "$desired" "$status"
      printf '        submitted %s\n' "$created"
    done <<< "$p"
  fi
  echo
}

file_requests() {
  echo
  require_account
  echo "Filing increase requests to $DESIRED vCPU in $REGION"
  hr
  while IFS=$'\t' read -r code name value; do
    [ -z "${code:-}" ] && continue
    v=${value%%.*}
    if [ "${v:-0}" -ge "$DESIRED" ] 2>/dev/null; then
      echo "  skip  $name already at $value"
      continue
    fi
    out=$(aws service-quotas request-service-quota-increase \
            --service-code ec2 --region "$REGION" \
            --quota-code "$code" --desired-value "$DESIRED" \
            --output json 2>&1)
    if echo "$out" | grep -q '"Id"'; then
      echo "  filed $name -> $DESIRED"
    elif echo "$out" | grep -q "ResourceAlreadyExistsException"; then
      echo "  open request already exists for $name"
    else
      echo "  FAILED $name"
      echo "        $(echo "$out" | head -1)"
    fi
  done <<< "$(lookup)"
  echo
  echo "Approval takes minutes to a couple of business days."
  echo "Track it: ./request-gpu-quota.sh --watch"
  echo
}

watch_loop() {
  echo
  require_account
  echo "Polling every 5 minutes. Ctrl-C to stop."
  while true; do
    ready=1
    while IFS=$'\t' read -r code name value; do
      [ -z "${code:-}" ] && continue
      v=${value%%.*}
      [ "${v:-0}" -ge 4 ] 2>/dev/null || ready=0
    done <<< "$(lookup)"

    if [ "$ready" -eq 1 ]; then
      echo
      printf '\033[32m[%s] quotas approved. Run ./preflight.sh\033[0m\n' "$(date +%H:%M)"
      command -v osascript >/dev/null 2>&1 && \
        osascript -e 'display notification "GPU quota approved" with title "Nameplate Analytics"' 2>/dev/null
      exit 0
    fi
    printf '[%s] still pending\n' "$(date +%H:%M)"
    sleep 300
  done
}

case "$MODE" in
  --file)   file_requests; show_status ;;
  --watch)  watch_loop ;;
  *)        show_status ;;
esac