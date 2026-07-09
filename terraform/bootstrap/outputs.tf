output "compartment_ocid" {
  description = "Feed into terraform/primary/terraform.tfvars."
  value       = oci_identity_compartment.k8s_lab.id
}

output "compartment_name" {
  value = oci_identity_compartment.k8s_lab.name
}

output "namespace" {
  value = local.namespace
}

output "state_bucket" {
  value = oci_objectstorage_bucket.tfstate.name
}

output "state_backend_endpoint" {
  description = "Feed into terraform/primary/backend.hcl as 'endpoint'."
  value       = "https://${local.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "ocir_repo_paths" {
  description = "Full image path per service, e.g. iad.ocir.io/<ns>/cart."
  value       = local.ocir_repo_paths
}

# Sensitive — shown once at apply time; copy into terraform/primary/backend.hcl.
output "state_aws_access_key_id" {
  value     = oci_identity_customer_secret_key.state.id
  sensitive = true
}

output "state_aws_secret_access_key" {
  value     = oci_identity_customer_secret_key.state.key
  sensitive = true
}
