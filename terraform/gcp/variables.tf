variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "GCP region."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "GCP zone."
  default     = "us-central1-a"
}

variable "instance_name" {
  type        = string
  description = "Instance name."
  default     = "vtpm-ssh"
}

variable "machine_type" {
  type        = string
  description = "Machine type (2 vCPU is plenty)."
  default     = "e2-standard-2"
}

variable "ssh_user" {
  type        = string
  description = "Guest username for the injected admin SSH key (provisioning only)."
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key (OpenSSH format) for the admin user. Provisioning key, NOT the operator device-identity path."
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR allowed to reach port 22. Defaults open — the hardware SSH cert is the gate. Narrow to your /32 for network-layer scoping on top."
  default     = "0.0.0.0/0"
}

variable "use_spot" {
  type        = bool
  description = "Use SPOT provisioning. Leave false for a clean stop/start."
  default     = false
}
