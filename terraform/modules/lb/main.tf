# ============================================================================
# Public flexible Load Balancer in front of the Kubernetes cluster.
#
# Request flow:
#   internet:80 → LB public IP (this file)
#                   ├── listener :80 (HTTP protocol) — the "front door"
#                   └── backend set (health-checked pool of worker NodePorts)
#                          ├── worker-1:30080  ┐
#                          └── worker-2:30080  ┴ Istio ingress-gateway (Phase 6+)
#                                                → in-cluster Services → app pods
#
# Phase-1 scope: HTTP(80) only. The nsg-lb 443 NSG ingress rule already exists,
# but the HTTPS *listener* (this file, resource type oci_load_balancer_listener)
# needs a certificate resource that only gets created at Phase 6 when Istio
# gateway/TLS lands. Adding an HTTPS listener now would fail — the cert
# reference has nothing to point at.
# ============================================================================


# ---------------------------------------------------------------------------
# 1) The Load Balancer itself.
#    OCI "flexible" shape lets us pin min/max bandwidth (default 10/10 Mbps
#    = Always-Free-eligible). It gets a public IP (is_private = false), sits
#    in the public subnet, and gets nsg-lb attached (which allows 80/443 in
#    from 0.0.0.0/0 and 30080/30443 out to nsg-workers — see nsg.tf).
# ---------------------------------------------------------------------------
resource "oci_load_balancer_load_balancer" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-lb"
  shape          = "flexible"

  shape_details {
    minimum_bandwidth_in_mbps = var.min_bandwidth_mbps
    maximum_bandwidth_in_mbps = var.max_bandwidth_mbps
  }

  subnet_ids                 = [var.public_subnet_id]
  network_security_group_ids = var.nsg_ids
  is_private                 = false
}


# ---------------------------------------------------------------------------
# 2) Backend set — the pool of "where to forward" targets + the health check
#    that decides which targets are eligible.
#
#    Policy ROUND_ROBIN: send each new connection to the next healthy backend
#    in the pool. Simple, sufficient for a lab; alternatives (LEAST_CONNECTIONS,
#    IP_HASH) matter more once you have real traffic patterns to optimize for.
#
#    Health check: raw TCP handshake against the worker NodePort. If the SYN/
#    SYN-ACK completes, the backend is "healthy". We use TCP (not HTTP) because
#    at Phase 1 the NodePort just points at a placeholder Service; a proper
#    HTTP health check ("GET /healthz, expect 200") lands at Phase 6 once Istio
#    ingress-gateway is behind it.
# ---------------------------------------------------------------------------
resource "oci_load_balancer_backend_set" "http" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "${var.name_prefix}-bs-http"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol = "TCP"
    port     = var.nodeport_http
  }
}


# ---------------------------------------------------------------------------
# 3) Backends — one entry per worker node in the pool.
#    `for_each` over the worker private IPs passed in from primary/main.tf
#    (values(module.workers.private_ips)). Each backend registers a specific
#    <worker-ip>:<NodePort> as a forwarding target inside the backend set.
#    Grows automatically if worker_count changes — no manual edits needed.
# ---------------------------------------------------------------------------
resource "oci_load_balancer_backend" "workers" {
  # Iterate over the map so `for_each` keys are the worker names (worker-1,
  # worker-2), known at plan time. The IP values are only known at apply time
  # — that's fine because for_each keys drive Terraform's resource addressing.
  for_each = var.backend_ips

  load_balancer_id = oci_load_balancer_load_balancer.this.id
  backendset_name  = oci_load_balancer_backend_set.http.name
  ip_address       = each.value
  port             = var.nodeport_http
}


# ---------------------------------------------------------------------------
# 4) Listener — the LB's public-facing "front door".
#    Binds port 80 on the LB's public IP to the backend set above. Traffic
#    arriving at http://<lb-ip>:80 gets forwarded to a healthy worker's
#    NodePort 30080. Protocol HTTP (L7) lets the LB add X-Forwarded-For and
#    handle Connection: keep-alive — useful for Istio's ingress-gateway.
#    HTTPS (port 443) listener is added at Phase 6 with a cert reference.
# ---------------------------------------------------------------------------
resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "${var.name_prefix}-listener-http"
  default_backend_set_name = oci_load_balancer_backend_set.http.name
  port                     = 80
  protocol                 = "HTTP"
}
