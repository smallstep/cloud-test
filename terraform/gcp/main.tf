terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Ubuntu 24.04 LTS, UEFI-capable (required for Shielded VM).
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_compute_firewall" "ssh" {
  name    = "vtpm-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Only SSH is exposed, and the HARDWARE SSH CERTIFICATE is the access control:
  # sshd trusts the Smallstep SSH user CA (TrustedUserCAKeys). Default is open so
  # you can prove "reachable, but refused without the cert" from anywhere — narrow
  # ssh_ingress_cidr to your /32 for network-layer scoping on top of the cert gate.
  source_ranges = [var.ssh_ingress_cidr]
  target_tags   = ["vtpm-ssh"]
}

resource "google_compute_instance" "vm" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["vtpm-ssh"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  # Shielded VM: vTPM + Secure Boot + integrity monitoring.
  shielded_instance_config {
    enable_vtpm                 = true
    enable_secure_boot          = true
    enable_integrity_monitoring = true
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_public_key}"
  }

  scheduling {
    provisioning_model  = var.use_spot ? "SPOT" : "STANDARD"
    preemptible         = var.use_spot
    automatic_restart   = !var.use_spot
    on_host_maintenance = var.use_spot ? "TERMINATE" : "MIGRATE"
  }
}
