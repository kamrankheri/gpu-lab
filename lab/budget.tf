# ---------------------------------------------------------------------------
# Budget alerts
# ---------------------------------------------------------------------------
# Activating advanced features REMOVED your hard spend limit and it cannot be
# recreated. This resource only notifies. The thing that actually stops spend
# is the auto-shutdown timer in user_data.sh.tftpl.

resource "aws_budgets_budget" "account_monthly" {
  name         = "nameplate-lab-account-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Actual spend crossing half the budget. Early warning.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # AWS's own forecast crossing the full budget. This is the one that catches
  # a runaway instance on day 3 instead of day 28.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "instance_id" {
  description = "Correlate this against your own CUR export later."
  value       = aws_instance.gpu.id
}

output "public_ip" {
  value = aws_instance.gpu.public_ip
}

output "ami_used" {
  value = local.ami_id
}

output "ssh" {
  value = "ssh -i ~/.ssh/nameplate-lab-lab ubuntu@${aws_instance.gpu.public_ip}"
}

output "metrics_tunnel" {
  description = "Forwards dcgm-exporter to localhost:9400 without exposing it."
  value       = "ssh -i ~/.ssh/nameplate-lab-lab -N -L 9400:localhost:9400 ubuntu@${aws_instance.gpu.public_ip}"
}
