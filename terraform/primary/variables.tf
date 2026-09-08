# ---- Identity / provider ----
variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID."
}

variable "region" {
  type    = string
  default = "us-ashburn-1"
}

variable "oci_config_profile" {
  type    = string
  default = "DEFAULT"
}

# ---- Compartment (from terraform/bootstrap outputs) ----
variable "compartment_ocid" {
  type        = string
  description = "OCID of the k8s-lab compartment (bootstrap output compartment_ocid)."
}

variable "compartment_name" {
  type    = string
  default = "platform-engine"
}

# ---- Naming ----
variable "name_prefix" {
  type    = string
  default = "platform-engine"
}

# ---- Network ----
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
  description = "Your public IP as a /32 — the only source allowed to SSH the bastion."
}

variable "allow_bastion_public_ssh" {
  type    = bool
  default = false
}

# ---- Access ----
variable "ssh_public_key" {
  type        = string
  description = "Public key content trusted by bastion/control-plane/workers (contents of ~/.ssh/k8s_lab_ed25519.pub)."
}

# ---- Availability domain ----
variable "availability_domain_index" {
  type        = number
  description = "Which AD (index into the tenancy's AD list) holds Always-Free capacity for this region. Check Governance > Limits if index 0 has none."
  default     = 0
}

# ---- Bastion (Always Free E2.1.Micro — separate pool from the A1.Flex budget) ----
variable "bastion_shape" {
  type    = string
  default = "VM.Standard.E2.1.Micro"
}

# ---- Control plane / workers (Always Free A1.Flex — 4 OCPU / 24GB total budget) ----
variable "cp_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "cp_ocpus" {
  type    = number
  default = 2
}

variable "cp_memory_in_gbs" {
  type    = number
  default = 8
}

variable "worker_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "worker_ocpus" {
  type    = number
  default = 1
}

variable "worker_memory_in_gbs" {
  type    = number
  default = 8
}

variable "boot_volume_size_in_gbs" {
  type    = number
  default = 50
}

# ---- LB ----
variable "nodeport_http" {
  type    = number
  default = 30080
}
