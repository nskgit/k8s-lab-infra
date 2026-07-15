terraform {
  required_version = ">= 1.11"

  # Bootstrap uses LOCAL state on purpose — it creates the remote backend that
  # everything else (primary/, dr/) then uses. Applied once, ever, by one operator.
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.23"
    }
  }
}

provider "oci" {
  region              = var.region
  tenancy_ocid        = var.tenancy_ocid
  config_file_profile = var.oci_config_profile
}
