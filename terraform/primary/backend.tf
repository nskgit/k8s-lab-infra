# Remote, LOCKED state in OCI Object Storage (S3-compatible API).
# Config is partial on purpose — supply the bucket/namespace at init:
#   terraform init -backend-config=backend.hcl
# (see backend.hcl.example). For local validate/plan only: terraform init -backend=false
terraform {
  backend "s3" {}
}
