variable "compartment_ocid" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "k8s-lab"
}

variable "role" {
  type        = string
  description = "Node role — tagging/naming metadata only; no networking logic branches on this."

  validation {
    condition     = contains(["bastion", "control-plane", "worker"], var.role)
    error_message = "role must be one of: bastion, control-plane, worker."
  }
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "subnet_id" {
  type = string
}

variable "nsg_ids" {
  type = list(string)
}

variable "assign_public_ip" {
  type    = bool
  default = false
}

variable "reserved_public_ip" {
  type        = bool
  description = "Attach a RESERVED (not ephemeral) public IP — used for the bastion."
  default     = false
}

variable "availability_domain" {
  type = string
}

variable "shape" {
  type = string
}

variable "is_flex_shape" {
  type        = bool
  description = "True for Flex shapes (A1.Flex), which accept a shape_config block; false for fixed shapes (E2.1.Micro)."
  default     = true
}

variable "ocpus" {
  type    = number
  default = null
}

variable "memory_in_gbs" {
  type    = number
  default = null
}

variable "boot_volume_size_in_gbs" {
  type    = number
  default = 50
}

variable "image_ocid" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
