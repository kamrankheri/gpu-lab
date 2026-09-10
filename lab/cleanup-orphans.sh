#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup-orphans.sh - delete Nameplate Analytics resources that exist in AWS but are
# absent from Terraform state.
#
#   ./cleanup-orphans.sh          show what would be deleted
#   ./cleanup-orphans.sh --yes    actually delete
#
# Happens when terraform.tfstate is deleted (or a working directory is wiped)
# while the AWS resources survive. Terraform then tries to create them again
# and every one fails as a duplicate.
#
# In a client account you would `terraform import` instead of deleting. Here,
# deletion is correct: these are throwaway lab resources, and the key pair MUST
# be recreated because the local SSH key was regenerated and no longer matches.
# ---------------------------------------------------------------------------
set -uo pipefail

REGION="${REGION:-us-east-2}"
DO_IT=0
[ "${1:-}" = "--yes" ] && DO_IT=1

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "${WORKING_ACCOUNT:-}" ]; then
  echo "Set WORKING_ACCOUNT to the account id this lab may touch." >&2; exit 1
fi
if [ "$ACCOUNT" != "$WORKING_ACCOUNT" ]; then
  echo "wrong account ($ACCOUNT). run: kkaws  and select Nameplate Analytics"
  exit 1
fi

if [ -f terraform.tfstate ] || [ -d .terraform ]; then
  STATE=$(terraform state list 2>/dev/null)
else
  STATE=""
fi

run() {
  if [ "$DO_IT" -eq 1 ]; then
    echo "    running: $*"
    "$@" && echo "    deleted" || echo "    FAILED"
  else
    echo "    would run: $*"
  fi
}

echo
echo "account $ACCOUNT  region $REGION  mode: $([ $DO_IT -eq 1 ] && echo DELETE || echo dry-run)"
echo "-----------------------------------------------------------"

# key pair
KP=$(aws ec2 describe-key-pairs --region "$REGION" --key-names nameplate-lab-lab \
       --query 'KeyPairs[0].KeyName' --output text 2>/dev/null)
if [ -n "$KP" ] && [ "$KP" != "None" ] && ! echo "$STATE" | grep -q '^aws_key_pair.lab$'; then
  echo "  orphan: key pair nameplate-lab-lab"
  run aws ec2 delete-key-pair --key-name nameplate-lab-lab --region "$REGION"
else
  echo "  ok: key pair"
fi

# security group
SG=$(aws ec2 describe-security-groups --region "$REGION" \
       --filters "Name=group-name,Values=nameplate-lab-lab" \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [ -n "$SG" ] && [ "$SG" != "None" ] && ! echo "$STATE" | grep -q '^aws_security_group.lab$'; then
  echo "  orphan: security group $SG"
  run aws ec2 delete-security-group --group-id "$SG" --region "$REGION"
else
  echo "  ok: security group"
fi

# budget (global, no --region)
BUD=$(aws budgets describe-budget --account-id "$ACCOUNT" \
        --budget-name nameplate-lab-account-monthly \
        --query 'Budget.BudgetName' --output text 2>/dev/null)
if [ -n "$BUD" ] && [ "$BUD" != "None" ] && ! echo "$STATE" | grep -q '^aws_budgets_budget.account_monthly$'; then
  echo "  orphan: budget nameplate-lab-account-monthly"
  run aws budgets delete-budget --account-id "$ACCOUNT" --budget-name nameplate-lab-account-monthly
else
  echo "  ok: budget"
fi

echo "-----------------------------------------------------------"
[ "$DO_IT" -eq 0 ] && echo "  dry run. re-run with --yes to delete." && echo
exit 0
