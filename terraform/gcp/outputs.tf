output "instance_id" {
  value       = google_compute_instance.vm.instance_id
  description = "Numeric instance ID."
}

output "instance_name" {
  value       = google_compute_instance.vm.name
  description = "Instance name — target for 'gcloud compute instances get-shielded-identity'."
}

output "public_ip" {
  value       = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
  description = "Ephemeral public IP for SSH."
}

output "ssh_user" {
  value       = var.ssh_user
  description = "Admin/provisioning user (key-based). The operator logs in as `operator` via the SSH cert."
}
