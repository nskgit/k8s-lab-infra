output "instance_ids" {
  value = { for k, v in oci_core_instance.node : k => v.id }
}

output "private_ips" {
  value = { for k, v in oci_core_instance.node : k => v.private_ip }
}

output "public_ip" {
  description = "Reserved public IP (bastion only); null otherwise."
  value       = try(values(oci_core_public_ip.reserved)[0].ip_address, null)
}
