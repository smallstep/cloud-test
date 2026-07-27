variable "region" {
  type        = string
  description = "AWS region to launch the NitroTPM instance in."
  default     = "us-east-1"
}

variable "instance_type" {
  type        = string
  description = "Nitro instance type (NitroTPM requires a Nitro platform)."
  default     = "m7i.large"
}

variable "key_name" {
  type        = string
  description = "Name for the EC2 key pair created from ssh_public_key (admin/provisioning user only)."
  default     = "vtpm-ssh"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key (OpenSSH format) for the admin `ubuntu` user. This is the provisioning key, NOT the operator device-identity path."
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR allowed to reach port 22. Defaults open — the hardware SSH cert is the gate. Narrow to your /32 for network-layer scoping on top."
  default     = "0.0.0.0/0"
}

variable "use_spot" {
  type        = bool
  description = "Use a Spot instance to cut cost. Leave false if you want a clean stop/start."
  default     = false
}
