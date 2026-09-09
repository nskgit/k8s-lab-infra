variable "compartment_ocid" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "vcn_id" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "nsg_lb_id" {
  type        = string
  description = "The LB's NSG — the edge gateway's egress rule targets it, not a raw CIDR/IP, so the LB can change address without touching this module."
}

variable "domain" {
  type        = string
  description = "Public DNS zone name (must already exist as a PRIMARY zone in OCI DNS, nameservers delegated at the registrar)."
}

variable "dns_zone_id" {
  type        = string
  description = "OCID of that zone. The provider has no data source to look this up by name, so it's passed in explicitly (same convention as compartment_ocid)."
}

variable "lb_public_ip" {
  type        = string
  description = "Current LB public IP — written once into the origin.<domain> A record. Free to change on a future LB replacement; nothing else in the request path depends on IPs after that."
}

variable "edge_hostnames" {
  type        = list(string)
  description = "Second-level labels (not FQDNs) that get a DNS steering policy attachment, e.g. [\"grafana\", \"echo\"] for grafana.<domain>. Each must already have an Istio HTTPRoute for \"<label>.<domain>\" — this module only handles the path in front of Istio."
}

variable "edge_certificate_pem" {
  type        = string
  sensitive   = true
  description = "Leaf certificate (PEM) for the API Gateway's custom domain. Day-1: the same lab wildcard cert already used by Istio (TLS_WILDCARD_CERT_PEM secret) — see edge-cert.yml for the follow-up that swaps this to a Let's-Encrypt-issued cert on a schedule."
}

variable "edge_certificate_key_pem" {
  type        = string
  sensitive   = true
  description = "Private key (PEM) matching edge_certificate_pem."
}

variable "health_check_vantage_points" {
  type    = list(string)
  default = ["aws-lhr", "goo-cbf", "azr-ord"]
}
