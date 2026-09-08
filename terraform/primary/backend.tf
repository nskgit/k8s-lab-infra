# Remote, LOCKED state in OCI Object Storage — native backend (Terraform
# >= 1.12), not the S3-compatible shim this used before. Migrated
# 2026-09-08: HashiCorp added a first-party `oci` backend type, and
# Oracle's own guidance now calls the S3-compatible approach deprecated.
# Auth reuses the exact same OCI config-file profile the provider already
# uses (see providers.tf) — no separate AWS-shaped credential needed, so
# the Customer Secret Key this used to require is no longer necessary.
#
# Config is partial on purpose — supply bucket/namespace at init:
#   terraform init -backend-config=backend.hcl
# (see backend.hcl.example). For local validate/plan only: terraform init -backend=false
terraform {
  backend "oci" {}
}
