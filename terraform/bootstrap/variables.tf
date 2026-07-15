# ---- OCI identity ----
variable "tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID (from ~/.oci/config)."
}

variable "user_ocid" {
  type        = string
  description = "OCID of the API user — owns the generated state-backend Customer Secret Key."
}

variable "region" {
  type    = string
  default = "us-ashburn-1"
}

variable "region_key" {
  type        = string
  description = "Short region key used in the OCIR host (us-ashburn-1 -> iad)."
  default     = "iad"
}

variable "oci_config_profile" {
  type    = string
  default = "DEFAULT"
}

# ---- Compartment ----
variable "compartment_name" {
  type    = string
  default = "k8s-lab"
}

# ---- Remote state ----
variable "state_bucket_name" {
  type    = string
  default = "k8s-lab-tfstate"
}

# ---- OCIR ----
variable "ocir_repo_names" {
  type        = list(string)
  description = "One OCIR repo per service (wave-1 set + Phase 9-lite hello-api)."
  default     = ["storefront", "catalog", "cart", "orders", "auth", "hello-api"]
}

# Note: `ocir_repos_immutable` variable removed — OCI's CreateContainerRepository
# API rejects `isImmutable` in us-ashburn-1 (400-BAD_REQUEST). Tag immutability
# is enforced at CI level (Phase 9) instead. See main.tf for the rationale.
