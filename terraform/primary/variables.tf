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

# ---- Edge (public DNS steering -> API Gateway -> LB -> Istio, 2026-09-09) ----
variable "domain" {
  type        = string
  default     = "satheshkumarnapoleon.site"
  description = "Public DNS zone name — must already exist as a PRIMARY zone in OCI DNS with nameservers delegated at the registrar."
}

variable "dns_zone_id" {
  type        = string
  description = "OCID of the domain's zone (OCI DNS > Zones > <domain> > OCID). No provider data source can look this up by name."
}

variable "edge_hostnames" {
  type = list(string)
  # "intranet" deliberately excluded: it's isolated on a separate internal
  # gateway with no LB listener at all (public -> 404 by design). Steering
  # a public DNS name at it here would just advertise a path that always
  # fails, with no way for the shared health check to catch it per-hostname.
  default     = ["blog", "db-admin", "echo", "grafana", "hello-api", "httpbin", "podinfo"]
  description = "Second-level labels that get DNS steering (each must have a matching Istio HTTPRoute already)."
}

variable "edge_certificate_pem" {
  type        = string
  sensitive   = true
  description = "API Gateway custom-domain leaf cert (PEM). CD supplies this from a GitHub secret; no default — never commit a real value."
}

variable "edge_certificate_key_pem" {
  type        = string
  sensitive   = true
  description = "Private key (PEM) matching edge_certificate_pem."
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

variable "cp_private_ip" {
  type        = string
  default     = null
  description = "Optional static private IP for the control-plane node (must fall inside cp_subnet_cidr). null lets OCI/DHCP assign it — the only safe default for a fresh tenancy. Set in terraform.tfvars to keep Ansible's kubeadm config (apiserver advertise address / control-plane endpoint) deterministic across a rebuild."
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
