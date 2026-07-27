terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

provider "aws" {
  region = var.region
}

# Stock Canonical Ubuntu 24.04 (Noble), x86_64. The published Canonical AMIs are
# boot-mode=uefi-preferred with TpmSupport=None — NitroTPM is NOT enabled on them.
# Per the AWS guide (enable-nitrotpm-support-on-ami), NitroTPM is turned on by
# setting TpmSupport=v2.0 on an AMI you OWN. So we copy the stock image into our
# account with tpm_support=v2.0 + boot_mode=uefi (below) and launch from the copy.
# aws_ami_copy deregisters the AMI + deletes its snapshot on destroy.
data "aws_ami" "ubuntu_base" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Step 1: copy the stock AMI into this account so we own a snapshot we can
# re-register with NitroTPM enabled.
resource "aws_ami_copy" "owned" {
  name              = "vtpm-ssh-base-copy-noble"
  source_ami_id     = data.aws_ami.ubuntu_base.id
  source_ami_region = var.region

  tags = { Name = "vtpm-ssh-base-copy" }
}

# Step 2: register a new AMI from the owned snapshot WITH NitroTPM enabled
# (TpmSupport=v2.0) + UEFI boot — the AWS-documented way to turn on the vTPM.
# On destroy: instance -> this AMI (deregister) -> the copy (deregister + delete
# snapshot), so teardown is clean.
resource "aws_ami" "nitrotpm" {
  # No description on purpose: a non-empty description makes the hashicorp/aws
  # provider issue a ModifyImageAttribute on re-apply that fails with
  # MissingParameter. The name documents the AMI.
  name                = "vtpm-ssh-nitrotpm-noble"
  architecture        = "x86_64"
  virtualization_type = "hvm"
  ena_support         = true
  root_device_name    = aws_ami_copy.owned.root_device_name
  boot_mode           = "uefi"
  tpm_support         = "v2.0"

  ebs_block_device {
    device_name           = aws_ami_copy.owned.root_device_name
    snapshot_id           = aws_ami_copy.owned.root_snapshot_id
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = { Name = "vtpm-ssh-nitrotpm" }
}

resource "aws_key_pair" "vm" {
  key_name   = var.key_name
  public_key = var.ssh_public_key
}

resource "aws_security_group" "vm" {
  name_prefix = "vtpm-ssh-"
  description = "SSH device-identity demo: SSH (22) gated by a hardware SSH cert"

  # Only SSH is exposed, and the HARDWARE SSH CERTIFICATE is the access control:
  # sshd trusts the Smallstep SSH user CA (TrustedUserCAKeys), so the port can be
  # reachable while remaining un-loginnable without a valid, attested cert.
  # Default is open so you can prove "reachable, but refused without the cert"
  # from anywhere — narrow ssh_ingress_cidr to your /32 for network-layer scoping
  # on top of the cert gate.
  ingress {
    description = "SSH - the hardware SSH cert is the gate"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    description = "All egress (needed for ACME device-attest-01 enrollment)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vtpm-ssh" }
}

resource "aws_instance" "vm" {
  ami                         = aws_ami.nitrotpm.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.vm.key_name
  vpc_security_group_ids      = [aws_security_group.vm.id]
  associate_public_ip_address = true

  # IMDSv2 only.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "vtpm-ssh" }
}
