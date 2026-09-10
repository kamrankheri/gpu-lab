variable "aws_profile" {
  description = <<-EOT
    Leave empty when using `aws login`, which writes temporary credentials to
    the default profile. Only set this if you deliberately created a named
    profile with `aws configure --profile <name>`.
  EOT
  type        = string
  default     = ""
}

variable "region" {
  description = "Must match the Region your console is set to, or resources look invisible. Also must be permitted by the RegionFloor SCP on your organization."
  type        = string
  default     = "us-east-2"
}

variable "instance_type" {
  description = "g4dn.xlarge = 1x NVIDIA T4, 4 vCPU, 16 GiB. Cheapest instance that gives you a real GPU and real DCGM metrics."
  type        = string
  default     = "g4dn.xlarge"
}

variable "ami_id" {
  description = <<-EOT
    Pinned so a new AMI release cannot silently rebuild your lab. Verified
    2026-09-03 in us-east-2: Deep Learning Base OSS Nvidia Driver GPU AMI
    (Ubuntu 22.04) 20260902.

    AMI IDs are Region-specific. If you change region, set this to "" to let
    the data source look it up, then pin whatever it returns.
  EOT
  type        = string
  default     = "ami-0f26d07c404ab110d"
}

variable "use_spot" {
  description = <<-EOT
    Spot is cheaper but needs the "All G and VT Spot Instance Requests" quota,
    which is separate from the On-Demand one and approved separately.

    Default is false because On-Demand quota landed first. Flip to true once
    the Spot request clears; that is the only change needed.

    Cost note: g4dn.xlarge On-Demand runs roughly $0.50/hr (verify current
    pricing in the console). A four-hour session is a couple of dollars, which
    is fine against an $800 budget. Spot is typically a fraction of that.
  EOT
  type        = bool
  default     = false
}

variable "my_ip_cidr" {
  description = "Your public IP as a /32. Never 0.0.0.0/0 on port 22."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && !startswith(var.my_ip_cidr, "0.0.0.0")
    error_message = "Must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "public_key_path" {
  description = "Path to the SSH public key Terraform registers."
  type        = string
  default     = "~/.ssh/nameplate-lab-lab.pub"
}

variable "root_volume_gb" {
  description = "The DLAMI needs room for CUDA and container images."
  type        = number
  default     = 100
}

variable "auto_shutdown_hours" {
  description = <<-EOT
    Self-destruct timer. The instance runs 'shutdown -h' after this many hours.
    One-time spot requests terminate rather than stop, so this ends the billing.

    Since activating advanced features removes your hard spend limit, this is
    the only thing in the stack that STOPS spend rather than reporting on it.
    Treat it as load-bearing.
  EOT
  type        = number
  default     = 8
}

variable "monthly_budget_usd" {
  description = "AWS Budgets alert threshold. Alerts only, does not enforce."
  type        = number
  default     = 80
}

variable "budget_alert_email" {
  description = "Where budget alerts go. Use an address you actually read."
  type        = string
}
