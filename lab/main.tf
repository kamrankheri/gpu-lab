# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------
# Default VPC on purpose. A private-subnet design needs a NAT gateway, roughly
# $32/month plus data processing, spent before a single GPU workload runs.
# Client engagements get a real VPC. A lab does not.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Only consulted when ami_id is empty. The default is pinned, so this normally
# does not run at all.
data "aws_ami" "dlami" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : one(data.aws_ami.dlami[*].id)
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------
resource "aws_key_pair" "lab" {
  key_name   = "nameplate-lab-lab"
  public_key = file(pathexpand(var.public_key_path))
}

resource "aws_security_group" "lab" {
  name        = "nameplate-lab-lab"
  description = "SSH from operator IP only. No inbound metrics port."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Port 9400 (dcgm-exporter) is deliberately NOT opened. dcgm-exporter has no
  # authentication. On a public IP it is a free inventory of your GPU fleet for
  # anyone port-scanning. Reach it over an SSH tunnel instead:
  #   terraform output metrics_tunnel
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "nameplate-lab-lab" }
}

# ---------------------------------------------------------------------------
# The GPU node
# ---------------------------------------------------------------------------
resource "aws_instance" "gpu" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.lab.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.lab.id]

  # Only emitted when use_spot is true. An empty instance_market_options block
  # is not the same as omitting it, so this has to be a dynamic block.
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"

      spot_options {
        # One-time: terminates on interruption instead of trying to come back.
        # No zombie instances.
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  # The auto-shutdown timer in user_data runs `shutdown -h`. On a one-time spot
  # request that terminates the instance and ends all billing. On-Demand
  # defaults to STOPPING instead, which leaves the 100 GB root volume billing
  # forever while you assume the safety net caught it. Force terminate.
  #
  # null on spot because AWS sets it implicitly there and passing it can
  # conflict.
  instance_initiated_shutdown_behavior = var.use_spot ? null : "terminate"

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # IMDSv2 required. Closes the SSRF-to-credential-theft path IMDSv1 allows.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    auto_shutdown_hours = var.auto_shutdown_hours
  })

  # Editing user_data does nothing to a running instance unless it is replaced.
  # Making that explicit avoids a classic hour of confusion.
  user_data_replace_on_change = true

  tags = {
    Name        = "nameplate-lab-gpu-lab"
    environment = "development"
    team        = "nameplate-lab"
    workload    = "dcgm-lab"
  }
}
