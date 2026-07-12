variable "compartment_ocid" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "k8s-lab"
}

variable "public_subnet_id" {
  type = string
}

variable "nsg_ids" {
  type = list(string)
}

variable "backend_ips" {
  type        = map(string)
  description = "Worker node private IPs, keyed by worker name (module.workers.private_ips). Static keys (worker-1, worker-2) let for_each work at plan time even though the IP values are known only after apply."
}

variable "nodeport_http" {
  type    = number
  default = 30080
}

variable "nodeport_https" {
  type        = number
  default     = 30443
  description = "Worker NodePort exposing Istio ingress-gateway's HTTPS listener (Phase 6). LB forwards :443 TCP passthrough here; Envoy terminates TLS with the Gateway's tls Secret."
}

variable "min_bandwidth_mbps" {
  type    = number
  default = 10
}

variable "max_bandwidth_mbps" {
  type    = number
  default = 10
}
