output "instance_id" {
  value       = aws_instance.vm.id
  description = "EC2 instance ID — feeds 'aws ec2 get-instance-tpm-ek-pub' for EK inventory."
}

output "public_ip" {
  value       = aws_instance.vm.public_ip
  description = "Public IP for SSH."
}

output "ssh_user" {
  value       = "ubuntu"
  description = "Admin/provisioning user (key-based). The operator logs in as `operator` via the SSH cert."
}
