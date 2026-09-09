terraform {
  required_version = ">= 1.11" # mirror the other modules

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}
