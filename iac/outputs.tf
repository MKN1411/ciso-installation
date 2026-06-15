# ==============================================================================
# Terraform Outputs: OCI GRC Infrastructure
# ==============================================================================

output "instance_name" {
  value       = oci_core_instance.grc_instance.display_name
  description = "The display name of the created GRC compute instance."
}

output "instance_private_ip" {
  value       = oci_core_instance.grc_instance.private_ip
  description = "The private IP address of the GRC instance."
}

output "bastion_name" {
  value       = oci_bastion_bastion.grc_bastion.name
  description = "The name of the OCI Bastion service."
}

output "bastion_id" {
  value       = oci_bastion_bastion.grc_bastion.id
  description = "The OCID of the OCI Bastion service."
}

output "bastion_ssh_command_template" {
  value       = "oci bastion session create-port-forwarding --bastion-id ${oci_bastion_bastion.grc_bastion.id} --target-private-ip-address ${oci_core_instance.grc_instance.private_ip} --target-port 22 --key-details '{\"publicKeyContent\": \"YOUR_SSH_PUBLIC_KEY\"}' --remote-port 22 --display-name 'admin-session'"
  description = "OCI CLI Template command to create a secure port forwarding session via the Bastion."
}

output "grc_public_ip" {
  value       = oci_core_instance.grc_instance.public_ip
  description = "The public IP address of the GRC compute instance."
}

output "grc_public_url" {
  value       = "https://${oci_core_instance.grc_instance.public_ip}:8443"
  description = "The direct web URL to access the CISO Assistant GRC platform."
}
