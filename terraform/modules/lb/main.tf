# ============================================================================
# Public flexible Load Balancer in front of the Kubernetes cluster.
#
# Request flow (Phase 6+):
#   internet:80  → listener :80 (HTTP L7)    → backend-set http  → workers :30080
#   internet:443 → listener :443 (TCP L4)    → backend-set https → workers :30443
#                                              └── Istio ingress-gateway (Phase 6):
#                                                  Envoy terminates TLS here using
#                                                  the Gateway's tls Secret; LB
#                                                  does NOT decrypt anything.
#
# Corrected Phase 6 audit: the earlier comment said the HTTPS listener needs a
# `oci_load_balancer_certificate` resource. Wrong — TLS terminates at Envoy
# inside the cluster, so the LB does L4 passthrough on 443 (protocol = TCP),
# no LB certificate.
#
# Known limitation of TCP-443 passthrough: LB doesn't see client IP after TLS
# handshake. X-Forwarded-For is populated only on the HTTP:80 L7 path. Future
# options: PROXY protocol v2 header, or switch to an OCI Network LB (L4 source
# IP preservation). Phase 15 stretch decision.
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


# ---------------------------------------------------------------------------
# 5) Backend set for HTTPS (Phase 6) — mirror of the HTTP path, TCP-only.
#
#    Health check is TCP (not HTTP) because Envoy will 404 on `/` without a
#    route configured — an HTTP health check would mark BOTH backends down and
#    silently break HTTPS traffic to the cluster. TCP handshake to :30443
#    succeeds as soon as Istio ingress-gateway is up; that's all we need.
#
#    Optional proper HTTP-based health path: Istio ships a status port at 15021
#    which returns 200 for `/healthz/ready`. Would need NodePort 30021 pinned
#    on the gateway service + NSG lb→workers 30021 rule. Kept TCP for now.
# ---------------------------------------------------------------------------
resource "oci_load_balancer_backend_set" "https" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "${var.name_prefix}-bs-https"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol = "TCP"
    port     = var.nodeport_https
  }
}


# ---------------------------------------------------------------------------
# 6) Backends for HTTPS — same worker pool, different NodePort.
# ---------------------------------------------------------------------------
resource "oci_load_balancer_backend" "workers_https" {
  for_each = var.backend_ips

  load_balancer_id = oci_load_balancer_load_balancer.this.id
  backendset_name  = oci_load_balancer_backend_set.https.name
  ip_address       = each.value
  port             = var.nodeport_https
}


# ---------------------------------------------------------------------------
# 7) Listener :443 — TCP L4 passthrough.
#
#    Protocol TCP (not HTTPS): the LB does not decrypt. Bytes flow straight
#    through to worker :30443 where Envoy handles the TLS handshake using the
#    Gateway's kubernetes.io/tls Secret. No `oci_load_balancer_certificate`
#    resource needed — that's the corrected Phase-1 comment.
# ---------------------------------------------------------------------------
resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "${var.name_prefix}-listener-https"
  default_backend_set_name = oci_load_balancer_backend_set.https.name
  port                     = 443
  protocol                 = "TCP"
}
