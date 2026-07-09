# Dynamic group matches every instance in the k8s-lab compartment (bastion,
# control-plane, workers) — the standard OCI CCM/CSI reference pattern.
# Tightening this to exclude the bastion is a Phase 13 hardening item, not a
# Phase 1 blocker.
resource "oci_identity_dynamic_group" "ccm_csi_nodes" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-ccm-csi-nodes"
  description    = "All compute instances in the ${var.compartment_name} compartment — CCM/CSI + OCIR pull via Instance Principals."
  matching_rule  = "ALL {instance.compartment.id = '${var.compartment_ocid}'}"
}

resource "oci_identity_policy" "ccm_csi" {
  compartment_id = var.compartment_ocid
  name           = "${var.name_prefix}-ccm-csi-policy"
  description    = "Lets CCM/CSI manage volumes/instances/network/LBs and pull from OCIR — no static keys on nodes."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.ccm_csi_nodes.name} to manage volume-family in compartment ${var.compartment_name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.ccm_csi_nodes.name} to manage instance-family in compartment ${var.compartment_name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.ccm_csi_nodes.name} to manage virtual-network-family in compartment ${var.compartment_name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.ccm_csi_nodes.name} to manage load-balancers in compartment ${var.compartment_name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.ccm_csi_nodes.name} to read repos in compartment ${var.compartment_name}",
  ]
}
