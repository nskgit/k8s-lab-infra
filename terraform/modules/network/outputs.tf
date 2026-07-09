output "vcn_id" {
  value = oci_core_vcn.this.id
}

output "public_subnet_id" {
  value = oci_core_subnet.public.id
}

output "cp_subnet_id" {
  value = oci_core_subnet.cp.id
}

output "worker_subnet_id" {
  value = oci_core_subnet.workers.id
}

output "nsg_lb_id" {
  value = oci_core_network_security_group.lb.id
}

output "nsg_bastion_id" {
  value = oci_core_network_security_group.bastion.id
}

output "nsg_cp_id" {
  value = oci_core_network_security_group.cp.id
}

output "nsg_workers_id" {
  value = oci_core_network_security_group.workers.id
}
