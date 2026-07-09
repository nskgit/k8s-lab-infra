# ---------------------------------------------------------------------------
# Dedicated compartment for the whole lab (destroy it to clean up everything).
# ---------------------------------------------------------------------------
resource "oci_identity_compartment" "k8s_lab" {
  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = "Kubernetes-on-OCI hands-on lab — all resources live here."
  enable_delete  = true
}

# ---------------------------------------------------------------------------
# Remote state bucket (Object Storage, S3-compatible API; versioned).
# ---------------------------------------------------------------------------
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = oci_identity_compartment.k8s_lab.id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = var.state_bucket_name
  versioning     = "Enabled"
}

# Customer Secret Key -> used as the AWS_ACCESS_KEY_ID/SECRET pair for the s3-compatible backend.
resource "oci_identity_customer_secret_key" "state" {
  user_id      = var.user_ocid
  display_name = "${var.compartment_name}-tfstate-key"
}

# ---------------------------------------------------------------------------
# OCIR repositories — one per wave-1 service.
#
# is_immutable is deliberately NOT set here. OCI's Artifacts Container
# Repository API in us-ashburn-1 rejects `isImmutable` on CreateContainerRepository
# with 400-BAD_REQUEST ("Setting isImmutable is not currently supported"), even
# though the Terraform provider exposes the field. Tag immutability is instead
# enforced at CI level (Phase 9): the build workflow refuses to re-push an
# existing git-SHA tag. Optional Phase 15 stretch: add a null_resource +
# local-exec calling `oci artifacts container repository update --is-immutable
# true` post-create, since OCI accepts the setting on UPDATE where it rejects
# it on CREATE.
# ---------------------------------------------------------------------------
resource "oci_artifacts_container_repository" "wave1" {
  for_each = toset(var.ocir_repo_names)

  compartment_id = oci_identity_compartment.k8s_lab.id
  display_name   = each.value
  is_public      = false
}

locals {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  ocir_host = "${var.region_key}.ocir.io"
  ocir_repo_paths = {
    for name, repo in oci_artifacts_container_repository.wave1 :
    name => "${local.ocir_host}/${local.namespace}/${repo.display_name}"
  }
}
