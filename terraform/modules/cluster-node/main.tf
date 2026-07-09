locals {
  node_names = { for i in range(var.instance_count) : "${var.role}-${i + 1}" => i }
}

# No user_data/cloud-init here on purpose — Round 1 (Phase 2) is deliberately
# manual-over-SSH for interview-grade understanding; baking automation into
# node bring-up here would undercut that.
resource "oci_core_instance" "node" {
  for_each = local.node_names

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.name_prefix}-${each.key}"
  shape               = var.shape

  dynamic "shape_config" {
    for_each = var.is_flex_shape ? [1] : []
    content {
      ocpus         = var.ocpus
      memory_in_gbs = var.memory_in_gbs
    }
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    nsg_ids          = var.nsg_ids
    assign_public_ip = var.assign_public_ip
    hostname_label   = each.key
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  freeform_tags = merge(var.tags, {
    role = var.role
    node = each.key
  })
}

# ---------------------------------------------------------------------------
# Reserved public IP (bastion only) — looked up against the instance's
# primary private IP so it survives instance replacement.
# ---------------------------------------------------------------------------
data "oci_core_vnic_attachments" "node" {
  for_each = var.reserved_public_ip ? local.node_names : {}

  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.node[each.key].id
}

data "oci_core_private_ips" "node" {
  for_each = var.reserved_public_ip ? local.node_names : {}

  vnic_id = data.oci_core_vnic_attachments.node[each.key].vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "reserved" {
  for_each = var.reserved_public_ip ? local.node_names : {}

  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-${each.key}-public-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.node[each.key].private_ips[0].id
}
