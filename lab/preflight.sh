#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# preflight.sh - verify the account can actually do what Terraform is about to
# ask, BEFORE apply creates half a stack and then fails.
#
#   ./preflight.sh
#
# Every check is read-only or a --dry-run. Nothing here costs money or creates
# a resource.
# ---------------------------------------------------------------------------
set -uo pipefail

REGION="${REGION:-us-east-2}"
# Guard against building the lab in the wrong account. Set WORKING_ACCOUNT to
# your workload account id and MGMT_ACCOUNT to your org management account id,
# must never hold workloads.
WORKING_ACCOUNT="${WORKING_ACCOUNT:-}"
MGMT_ACCOUNT="${MGMT_ACCOUNT:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"
AMI="${AMI:-ami-0f26d07c404ab110d}"

# Which quota matters depends on how the instance will be launched. Checking
# the Spot quota when Terraform is configured for On-Demand (or vice versa)
# blocks a launch that would have worked.
USE_SPOT="false"
if [ -f terraform.tfvars ] && grep -qE '^[[:space:]]*use_spot[[:space:]]*=[[:space:]]*true' terraform.tfvars; then
  USE_SPOT="true"
fi
if [ "$USE_SPOT" = "true" ]; then
  QUOTA_MATCH="Spot Instance Requests"
  MARKET="spot"
else
  QUOTA_MATCH="Running On-Demand"
  MARKET="on-demand"
fi

PASS=0
FAIL=0

# Every counter increment must happen in THIS shell. No `cmd | while read`
# loops around ok/bad — the subshell swallows the count.

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

echo
echo "preflight: region=$REGION type=$INSTANCE_TYPE market=$MARKET"
echo "-----------------------------------------------------------"

# --- 1. Tooling ------------------------------------------------------------
for bin in aws terraform ssh-keygen jq; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin installed"
  elif [ "$bin" = "jq" ]; then
    warn "jq not installed (optional, improves output readability)"
  else
    bad "$bin not installed"
  fi
done

# --- 2. Pager ---------------------------------------------------------------
# AWS CLI v2 pipes through a pager by default, which suspends under some
# shells and makes every command look broken.
if [ "$(aws configure get cli_pager 2>/dev/null)" = "" ] && \
   ! grep -q 'cli_pager' "${HOME}/.aws/config" 2>/dev/null; then
  warn "cli_pager not disabled. Run: aws configure set cli_pager \"\""
else
  ok "cli_pager configured"
fi

# --- 3. Credentials ---------------------------------------------------------
# Stale exported credentials are the highest-priority source, so they mask a
# fresh `aws login` entirely. Diagnose this specifically: the generic "no
# credentials" message sends you looking in the wrong place.
if [ -n "${AWS_CREDENTIAL_EXPIRATION:-}" ]; then
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    bad "STALE credentials exported in this shell (expires ${AWS_CREDENTIAL_EXPIRATION})"
    info "Env vars outrank ~/.aws/credentials, so aws login cannot fix this."
    info "  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION"
    info "  aws login && eval \"\$(aws configure export-credentials --format env)\""
    info "Or just: kkaws   (see ~/nameplate-analytics/aws-session.sh)"
    echo; echo "Stopping."; exit 1
  fi
fi

CALLER=$(aws sts get-caller-identity --output json 2>&1)
if echo "$CALLER" | grep -q '"Account"'; then
  ACCOUNT=$(echo "$CALLER" | grep -o '"Account": *"[0-9]*"' | grep -o '[0-9]\{12\}')
  ARN=$(echo "$CALLER" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
  ok "credentials valid, account $ACCOUNT"
  info "$ARN"
  case "$ARN" in
    *:user/*) warn "long-lived IAM user. Prefer 'aws login' for temporary credentials." ;;
    *assumed-role*) ok "temporary role credentials (good)" ;;
  esac

  # Wrong-account guard. Building in the management account is a real mistake
  # with real cleanup, and nothing else in the stack catches it.
  if [ -n "$MGMT_ACCOUNT" ] && [ "$ACCOUNT" = "$MGMT_ACCOUNT" ]; then
    bad "You are in the ORG MANAGEMENT ACCOUNT ($MGMT_ACCOUNT)."
    info "Never run workloads here. Switch to the workload account ($WORKING_ACCOUNT)."
    echo; echo "Stopping."; exit 1
  elif [ -z "$WORKING_ACCOUNT" ]; then
    warn "WORKING_ACCOUNT is not set, so the wrong-account guard is off"
    info "export WORKING_ACCOUNT=<id> and MGMT_ACCOUNT=<id> to enable it"
  elif [ "$ACCOUNT" != "$WORKING_ACCOUNT" ]; then
    warn "expected working account $WORKING_ACCOUNT, got $ACCOUNT"
    info "Continuing, but confirm this is deliberate."
  else
    ok "correct working account"
  fi
else
  bad "no valid credentials"
  info "run: kkaws   (or: aws login && eval \"\$(aws configure export-credentials --format env)\")"
  info "$(echo "$CALLER" | head -1)"
  echo; echo "Stopping: nothing else can be checked."; exit 1
fi

# --- 3b. Can TERRAFORM get credentials, and will they last? -----------------
# Two distinct failure modes:
#   1. No credentials reachable by the SDK at all.
#   2. Exported env vars, which are a STATIC SNAPSHOT with no refresh path.
#      `aws login` credentials live ~15 minutes; frozen in env vars they die
#      mid-apply and there is nothing to refresh them from.
# The durable answer is the kkterraform profile (credential_process), which
# asks the CLI for live credentials on every request.
if aws sts get-caller-identity --profile kkterraform >/dev/null 2>&1; then
  ok "profile kkterraform resolves (credential_process, auto-refreshing)"
  grep -q 'kkterraform' terraform.tfvars 2>/dev/null \
    && ok "terraform.tfvars uses kkterraform" \
    || warn "set aws_profile = \"kkterraform\" in terraform.tfvars"
elif [ -n "${AWS_CREDENTIAL_EXPIRATION:-}" ]; then
  warn "using exported env credentials, which expire at ${AWS_CREDENTIAL_EXPIRATION}"
  info "these do not refresh. A long apply can die halfway."
  info "run kksetup once, then set aws_profile = \"kkterraform\""
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    bad "and they are ALREADY EXPIRED"
    info "  kkclear && kkaws"
    echo; echo "Stopping."; exit 1
  fi
elif grep -q '^\[default\]' "${HOME}/.aws/credentials" 2>/dev/null; then
  ok "default profile present in ~/.aws/credentials"
else
  bad "terraform will NOT find credentials"
  info "run: kksetup   (once), then kkaws"
fi

# Leaked-key guard.
if grep -q 'AKIA' "${HOME}/.aws/credentials" 2>/dev/null; then
  bad "a long-lived AKIA key is still in ~/.aws/credentials"
  info "delete that profile block. aws login does not need it."
fi

# --- 4. Region reachable ----------------------------------------------------
if aws ec2 describe-availability-zones --region "$REGION" \
     --query 'AvailabilityZones[0].ZoneName' --output text >/dev/null 2>&1; then
  ok "region $REGION reachable"
else
  bad "region $REGION not reachable. Check the RegionFloor SCP on your org."
fi

# --- 5. AMI exists in THIS region -------------------------------------------
# AMI IDs are region-specific. A pinned ID from another region silently fails.
AMI_NAME=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" \
             --query 'Images[0].Name' --output text 2>/dev/null)
if [ -n "$AMI_NAME" ] && [ "$AMI_NAME" != "None" ]; then
  ok "AMI $AMI exists in $REGION"
  info "$AMI_NAME"
else
  bad "AMI $AMI not found in $REGION. Set ami_id=\"\" to re-look-it-up."
fi

# --- 6. THE BIG ONE: can we actually launch? --------------------------------
# --dry-run performs the full authorization check and then refuses to act.
# Success looks like an error containing "DryRunOperation". Anything else is
# the real reason your apply is going to fail.
DRY=$(aws ec2 run-instances --dry-run --region "$REGION" \
        --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --count 1 2>&1)

if echo "$DRY" | grep -q "DryRunOperation"; then
  ok "ec2:RunInstances authorized for $INSTANCE_TYPE"
elif echo "$DRY" | grep -q "explicit deny in a service control policy"; then
  bad "BLOCKED by a Service Control Policy"
  POLICY=$(echo "$DRY" | grep -o 'arn:aws:organizations::[^ ]*' | head -1)
  info "policy: $POLICY"
  ORG_ACCT=$(echo "$POLICY" | sed -n 's/.*organizations::\([0-9]*\).*/\1/p')
  if [ -n "$ORG_ACCT" ] && [ "$ORG_ACCT" != "$ACCOUNT" ]; then
    info "That org ($ORG_ACCT) is not yours. You have not activated advanced"
    info "features yet. Go to https://settings.aws.com -> Projects -> Actions."
  fi
  ENC=$(echo "$DRY" | sed -n 's/.*Encoded authorization failure message: \([A-Za-z0-9_-]*\).*/\1/p')
  if [ -n "$ENC" ]; then
    info "decode it with:"
    info "  aws sts decode-authorization-message --encoded-message \"$ENC\" \\"
    info "    --query DecodedMessage --output text | python3 -m json.tool"
  fi
elif echo "$DRY" | grep -qE "VcpuLimitExceeded|MaxSpotInstanceCount"; then
  bad "quota too low for $INSTANCE_TYPE. File the G and VT increase."
elif echo "$DRY" | grep -q "UnauthorizedOperation"; then
  bad "not authorized (IAM, not SCP). Your role lacks ec2:RunInstances."
else
  bad "unexpected response from dry-run"
  info "$(echo "$DRY" | head -2)"
fi

# --- 7. GPU quota -----------------------------------------------------------
# Only the quota for the market type actually configured.
QUOTA=$(aws service-quotas list-service-quotas --service-code ec2 --region "$REGION" \
          --query "Quotas[?contains(QuotaName,'G and VT') && contains(QuotaName,'$QUOTA_MATCH')].[QuotaName,Value]" \
          --output text 2>/dev/null)
if [ -n "$QUOTA" ]; then
  # NOTE: `echo "$X" | while read` runs the loop in a SUBSHELL, so any counter
  # incremented inside is discarded when the subshell exits. That bug made this
  # script report "0 failed" on an account with zero GPU quota. Use a herestring
  # so the loop stays in the current shell.
  while IFS=$'\t' read -r name value; do
    [ -z "$name" ] && continue
    v=${value%%.*}
    if [ "${v:-0}" -ge 4 ] 2>/dev/null; then
      ok "quota: $name = $value vCPU"
    else
      bad "quota: $name = $value vCPU (need 4+ for $INSTANCE_TYPE)"
      info "Service Quotas -> EC2 -> search 'G and VT' -> request 8 vCPU"
      if [ "$USE_SPOT" = "true" ]; then
        info "Or set use_spot = false in terraform.tfvars to use On-Demand."
      fi
    fi
  done <<< "$QUOTA"
else
  warn "could not read G and VT quotas"
fi

# --- 8. SSH key -------------------------------------------------------------
if [ -f "${HOME}/.ssh/nameplate-lab-lab.pub" ]; then
  ok "SSH public key present"
  if [ "$(stat -f '%A' "${HOME}/.ssh/nameplate-lab-lab" 2>/dev/null || \
          stat -c '%a' "${HOME}/.ssh/nameplate-lab-lab" 2>/dev/null)" != "600" ]; then
    warn "private key permissions should be 600: chmod 600 ~/.ssh/nameplate-lab-lab"
  fi
else
  bad "no key at ~/.ssh/nameplate-lab-lab.pub"
  info "ssh-keygen -t ed25519 -f ~/.ssh/nameplate-lab-lab -C nameplate-lab-lab"
fi

# --- 8b. Orphans: resources in AWS that Terraform state does not know about --
# Deleting terraform.tfstate does not delete anything in AWS. The resources
# survive, the next apply tries to create them again, and you get a wall of
# InvalidKeyPair.Duplicate / InvalidGroup.Duplicate / DuplicateRecordException.
if [ -f terraform.tfstate ] || [ -d .terraform ]; then
  STATE=$(terraform state list 2>/dev/null)
else
  STATE=""
fi

_orphan_check() {
  local label="$1" in_aws="$2" state_addr="$3" fix="$4"
  [ -z "$in_aws" ] && return 0
  if echo "$STATE" | grep -q "^${state_addr}$"; then
    return 0
  fi
  bad "$label exists in AWS but not in terraform state"
  info "$fix"
}

KP=$(aws ec2 describe-key-pairs --region "$REGION" --key-names nameplate-lab-lab \
       --query 'KeyPairs[0].KeyName' --output text 2>/dev/null)
[ "$KP" = "None" ] && KP=""
_orphan_check "key pair nameplate-lab-lab" "$KP" "aws_key_pair.lab" \
  "aws ec2 delete-key-pair --key-name nameplate-lab-lab --region $REGION"

SG=$(aws ec2 describe-security-groups --region "$REGION" \
       --filters "Name=group-name,Values=nameplate-lab-lab" \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ "$SG" = "None" ] && SG=""
_orphan_check "security group nameplate-lab-lab" "$SG" "aws_security_group.lab" \
  "aws ec2 delete-security-group --group-id $SG --region $REGION"

BUD=$(aws budgets describe-budget --account-id "$ACCOUNT" \
        --budget-name nameplate-lab-account-monthly \
        --query 'Budget.BudgetName' --output text 2>/dev/null)
[ "$BUD" = "None" ] && BUD=""
_orphan_check "budget nameplate-lab-account-monthly" "$BUD" "aws_budgets_budget.account_monthly" \
  "aws budgets delete-budget --account-id $ACCOUNT --budget-name nameplate-lab-account-monthly"

# The public key on file must match the one on disk, or the instance launches
# with a key whose private half you no longer have and SSH fails in a way that
# does not look like a key problem.
if [ -n "$KP" ] && [ -f "${HOME}/.ssh/nameplate-lab-lab.pub" ]; then
  AWS_FP=$(aws ec2 describe-key-pairs --region "$REGION" --key-names nameplate-lab-lab \
             --include-public-key --query 'KeyPairs[0].PublicKey' --output text 2>/dev/null \
             | awk '{print $2}')
  LOCAL_FP=$(awk '{print $2}' "${HOME}/.ssh/nameplate-lab-lab.pub")
  if [ -n "$AWS_FP" ] && [ "$AWS_FP" != "$LOCAL_FP" ]; then
    bad "AWS key pair does NOT match ~/.ssh/nameplate-lab-lab.pub"
    info "you regenerated the key. Delete the AWS one and let terraform recreate it:"
    info "  aws ec2 delete-key-pair --key-name nameplate-lab-lab --region $REGION"
  fi
fi

# --- 9. Nothing already running ---------------------------------------------
RUNNING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=Nameplate Analytics" \
            "Name=instance-state-name,Values=running,pending" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)
if [ "${RUNNING:-0}" = "0" ]; then
  ok "no Nameplate Analytics instances already running"
else
  warn "$RUNNING Nameplate Analytics instance(s) already running. Check before applying."
fi

# --- 10. tfvars sanity ------------------------------------------------------
if [ -f terraform.tfvars ]; then
  ok "terraform.tfvars present"
  grep -q "REPLACE_ME" terraform.tfvars && bad "terraform.tfvars still has REPLACE_ME"
  MYIP=$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')
  if [ -n "$MYIP" ] && ! grep -q "$MYIP" terraform.tfvars; then
    warn "your IP is $MYIP but terraform.tfvars has a different one."
    warn "SSH will fail. Update my_ip_cidr to ${MYIP}/32"
  elif [ -n "$MYIP" ]; then
    ok "my_ip_cidr matches your current IP ($MYIP)"
  fi
else
  bad "no terraform.tfvars. cp terraform.tfvars.example terraform.tfvars"
fi

echo "-----------------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32m%d passed, 0 failed. Safe to run terraform plan.\033[0m\n\n' "$PASS"
  exit 0
else
  printf '  \033[31m%d passed, %d FAILED. Fix these before applying.\033[0m\n\n' "$PASS" "$FAIL"
  exit 1
fi
