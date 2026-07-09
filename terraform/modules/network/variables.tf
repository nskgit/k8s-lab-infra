variable "compartment_ocid" {
  type        = string
  description = "OCI compartment to create all network resources in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to resource display names (e.g. 'k8s-lab')."
  default     = "k8s-lab"
}

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "cp_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "worker_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP as a /32 CIDR — the only source allowed to SSH the bastion."

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && endswith(var.my_ip_cidr, "/32")
    error_message = "my_ip_cidr must be a /32 CIDR, e.g. 203.0.113.7/32."
  }
}

variable "allow_bastion_public_ssh" {
  type        = bool
  description = "If true, also allow SSH to the bastion from 0.0.0.0/0 (Phase A hosted-runner key-only access). Default off."
  default     = false
}
