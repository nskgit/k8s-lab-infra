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
    private_ip       = var.private_ip
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

  # FROZEN post-incident (2026-09-08 boot-volume-wipe incident, LEARNING-LOG
  # §15): source_id above resolves from an unpinned "latest matching image"
  # data source in primary/main.tf (sort_by=TIMECREATED desc, images[0]).
  # That value silently drifts whenever Oracle publishes a newer platform
  # image — with zero relation to anything this module's caller changes.
  # oci_core_instance.source_details.source_id is NOT schema-ForceNew, so
  # Terraform shows the drift as an innocuous "update in-place" (no
  # "forces replacement" tag) — but OCI's real behavior for an image change
  # is to re-provision the boot volume from the new image, wiping the
  # running OS. Proven: a "0 destroy" plan still replaced all 3 boot
  # volumes. ignore_changes freezes the image an existing instance boots
  # from forever after creation — a deliberate OS upgrade must taint+recreate
  # the instance explicitly, never happen as a side effect of an unrelated
  # apply.
  lifecycle {
    ignore_changes = [source_details]
  }
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
