data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# 2026-09-08: comment-only change — first real end-to-end exercise of the
# infra-cd.yml pipeline (terraform-apply -> ansible-configure -> smoke-test),
# per LEARNING-LOG §15's plan. Zero resource diff expected.

locals {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
}

# Two image lookups — bastion is x86 (E2.1.Micro), control-plane/workers are
# ARM (A1.Flex). Always Free budget forces this split: cp(2/8)+worker-1/2(1/8
# each) already consumes the entire 4 OCPU/24GB A1.Flex allowance, so the
# bastion must use the separate E2.1.Micro Always-Free pool.
data "oci_core_images" "ol_x86" {
  # tenancy_ocid, not compartment_ocid: platform images are Oracle-published
  # to the tenancy and inherited by every compartment. Querying with a specific
  # compartment_id works ONLY once the compartment exists (post-bootstrap-apply);
  # during plan-only review with a placeholder compartment_ocid, OCI can't find
  # the compartment and returns null, crashing at `.images[0]`.
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.bastion_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_images" "ol_arm" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.cp_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
module "network" {
  source = "../modules/network"

  compartment_ocid         = var.compartment_ocid
  name_prefix              = var.name_prefix
  vcn_cidr                 = var.vcn_cidr
  public_subnet_cidr       = var.public_subnet_cidr
  cp_subnet_cidr           = var.cp_subnet_cidr
  worker_subnet_cidr       = var.worker_subnet_cidr
  my_ip_cidr               = var.my_ip_cidr
  allow_bastion_public_ssh = var.allow_bastion_public_ssh
}

# ---------------------------------------------------------------------------
# IAM for CCM/CSI (Instance Principals — no static keys)
# ---------------------------------------------------------------------------
module "iam_ccm" {
  source = "../modules/iam-ccm"

  tenancy_ocid     = var.tenancy_ocid
  compartment_ocid = var.compartment_ocid
  compartment_name = var.compartment_name
}

# ---------------------------------------------------------------------------
# Nodes — same cluster-node module, three roles, zero forked code. Only the
# call-site arguments (subnet/nsg/shape/image) differ per role.
# ---------------------------------------------------------------------------
module "bastion" {
  source = "../modules/cluster-node"

  compartment_ocid        = var.compartment_ocid
  name_prefix             = var.name_prefix
  role                    = "bastion"
  instance_count          = 1
  subnet_id               = module.network.public_subnet_id
  nsg_ids                 = [module.network.nsg_bastion_id]
  assign_public_ip        = false
  reserved_public_ip      = true
  availability_domain     = local.availability_domain
  shape                   = var.bastion_shape
  is_flex_shape           = false
  image_ocid              = data.oci_core_images.ol_x86.images[0].id
  ssh_public_key          = var.ssh_public_key
  boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
}

module "control_plane" {
  source = "../modules/cluster-node"

  compartment_ocid        = var.compartment_ocid
  name_prefix             = var.name_prefix
  role                    = "control-plane"
  instance_count          = 1
  subnet_id               = module.network.cp_subnet_id
  nsg_ids                 = [module.network.nsg_cp_id]
  assign_public_ip        = false
  availability_domain     = local.availability_domain
  shape                   = var.cp_shape
  is_flex_shape           = true
  ocpus                   = var.cp_ocpus
  memory_in_gbs           = var.cp_memory_in_gbs
  image_ocid              = data.oci_core_images.ol_arm.images[0].id
  ssh_public_key          = var.ssh_public_key
  boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  private_ip              = var.cp_private_ip
}

module "workers" {
  source = "../modules/cluster-node"

  compartment_ocid        = var.compartment_ocid
  name_prefix             = var.name_prefix
  role                    = "worker"
  instance_count          = var.worker_count
  subnet_id               = module.network.worker_subnet_id
  nsg_ids                 = [module.network.nsg_workers_id]
  assign_public_ip        = false
  availability_domain     = local.availability_domain
  shape                   = var.worker_shape
  is_flex_shape           = true
  ocpus                   = var.worker_ocpus
  memory_in_gbs           = var.worker_memory_in_gbs
  image_ocid              = data.oci_core_images.ol_arm.images[0].id
  ssh_public_key          = var.ssh_public_key
  boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
}

# ---------------------------------------------------------------------------
# Load balancer — fronts the workers' NodePort.
# ---------------------------------------------------------------------------
module "lb" {
  source = "../modules/lb"

  compartment_ocid = var.compartment_ocid
  name_prefix      = var.name_prefix
  public_subnet_id = module.network.public_subnet_id
  nsg_ids          = [module.network.nsg_lb_id]
  backend_ips      = module.workers.private_ips
  nodeport_http    = var.nodeport_http
}

# ---------------------------------------------------------------------------
# Edge — public DNS steering (FAILOVER) -> API Gateway -> the LB above.
# ---------------------------------------------------------------------------
module "edge" {
  source = "../modules/edge"

  compartment_ocid         = var.compartment_ocid
  name_prefix              = var.name_prefix
  vcn_id                   = module.network.vcn_id
  public_subnet_id         = module.network.public_subnet_id
  nsg_lb_id                = module.network.nsg_lb_id
  domain                   = var.domain
  dns_zone_id              = var.dns_zone_id
  edge_hostnames           = var.edge_hostnames
  lb_public_ip             = module.lb.lb_public_ip
  edge_certificate_pem     = var.edge_certificate_pem
  edge_certificate_key_pem = var.edge_certificate_key_pem
}
