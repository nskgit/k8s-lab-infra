output "dynamic_group_id" {
  value = oci_identity_dynamic_group.ccm_csi_nodes.id
}

output "dynamic_group_name" {
  value = oci_identity_dynamic_group.ccm_csi_nodes.name
}

output "policy_id" {
  value = oci_identity_policy.ccm_csi.id
}
