terraform {
  required_version = ">= 1.11" # mirror the roots — modules declare their own floor

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.23"
    }
  }
}
