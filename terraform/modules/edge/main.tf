# ============================================================================
# edge — public DNS steering -> API Gateway -> LB -> Istio (2026-09-09).
#
# Built to a specific request: front the LB with DNS steering + an API
# Gateway instead of pointing DNS straight at it, with the OLD direct-to-LB
# path kept as the steering failover/"dummy" answer. This module is that
# architecture, not a fix for a smaller problem — see below for the one
# piece of it that happens to double as a real bug fix.
#
# Request path:
#   client -> DNS steering (FAILOVER) -> primary: CNAME to this API Gateway
#                                      -> secondary: CNAME to origin.<domain>
#                                         (a plain A record at the LB — the
#                                         pre-existing direct path)
#          -> API Gateway: rewrites Host back to the client's original Host
#             (Envoy picks the route by Host, not by what the gateway used
#             to reach it with), forwards to origin.<domain>
#          -> LB :443 (unchanged, L4 passthrough) -> Istio ingress Envoy
#             -> HTTPRoute by Host (unchanged — every existing route keeps
#             working with zero changes on that side)
#
# Why a health check on the FULL path (gateway -> origin -> Istio -> a real
# HTTPRoute), not just "is the gateway up": a gateway that's up but can't
# reach a healthy backend is exactly the case that should fail over to the
# direct path. /_edge/healthz is a route on THIS gateway that proxies to
# origin.<domain>/_edge/healthz, which is an Istio HTTPRoute (added
# alongside this module, see k8s-lab-gitops) pointing at httpbin's
# /status/200 — so a green health check means the whole chain works.
#
# The origin.<domain> A record (one write-site for the LB's public IP) is
# also, as a side effect, the D8 fix (docs/PHASES-4-15-EXECUTION-PLAN.md):
# a future LB replacement only needs this one record updated, and nothing
# above it (steering's secondary answer, the gateway's backend URL) needs
# to change. D8 motivates that one record, not the gateway/steering layer
# above it — that layer is the requested architecture.
# ============================================================================

# The oracle/oci provider has no data source for an existing DNS zone (only
# the resource, for creating one) — the zone OCID comes in as a variable,
# same convention this repo already uses for compartment_ocid etc.

locals {
  origin_fqdn = "origin.${var.domain}"

  # A dedicated, NOT-steered CNAME to the gateway, used only by the health
  # monitor below. Deliberately not the gateway's own OCI-generated
  # hostname: this module attaches ONE certificate to the whole gateway
  # (the wildcard for *.<domain>) — per OCI's own docs, that certificate
  # replaces whatever default cert the raw hostname would otherwise
  # present, so TLS to <gw-id>.apigateway.<region>.oci.customer-oci.com
  # fails hostname validation against a cert that doesn't cover it. A
  # plain <label>.<domain> CNAME matches the wildcard's SAN and resolves
  # to the same gateway (OCI API Gateway routes by path, not by which
  # hostname reached it, so /_edge/healthz answers identically either
  # way). It must NOT be one of edge_hostnames — probing through the very
  # steering policy the probe result feeds would be circular.
  edge_probe_fqdn = "edge-probe.${var.domain}"
}

# ── NSG — least privilege, mirrors nsg-lb's pattern (no catch-all egress) ──
resource "oci_core_network_security_group" "edge" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.name_prefix}-nsg-edge"
}

resource "oci_core_network_security_group_security_rule" "edge_in_https" {
  network_security_group_id = oci_core_network_security_group.edge.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Internet -> API Gateway:443"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "edge_out_lb_https" {
  network_security_group_id = oci_core_network_security_group.edge.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = var.nsg_lb_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "API Gateway -> LB:443 (origin.<domain>)"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# ── Certificate for the gateway's custom domain ────────────────────────────
# certificate/private_key aren't marked Updatable by the provider — a value
# change replaces this resource. create_before_destroy so the gateway is
# never briefly certificate-less during a rotation (see edge-cert.yml).
resource "oci_apigateway_certificate" "edge" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-edge-cert"
  certificate    = var.edge_certificate_pem
  private_key    = var.edge_certificate_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "oci_apigateway_gateway" "edge" {
  compartment_id             = var.compartment_ocid
  display_name               = "${var.name_prefix}-edge-gw"
  endpoint_type              = "PUBLIC"
  subnet_id                  = var.public_subnet_id
  network_security_group_ids = [oci_core_network_security_group.edge.id]
  certificate_id             = oci_apigateway_certificate.edge.id
}

resource "oci_apigateway_deployment" "edge" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-edge-deployment"
  gateway_id     = oci_apigateway_gateway.edge.id
  path_prefix    = "/"

  specification {
    # Full-path health probe (see header) — the gateway itself proxies
    # this to origin.<domain>, it is not a stock response.
    routes {
      path    = "/_edge/healthz"
      methods = ["GET"]

      backend {
        type                       = "HTTP_BACKEND"
        url                        = "https://${local.origin_fqdn}/_edge/healthz"
        is_ssl_verify_disabled     = true # origin presents the lab CA, not a public CA
        connect_timeout_in_seconds = 5
        read_timeout_in_seconds    = 5
        send_timeout_in_seconds    = 5
      }

      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "Host"
              values    = [local.origin_fqdn]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # Everything else: forward as-is, but with the ORIGINAL client Host
    # restored — ${request.host} and ${request.path[path]} are OCI API
    # Gateway context-variable expressions (escaped as $${...} below so
    # Terraform emits the literal string instead of interpolating it),
    # not Terraform interpolation. Without the Host rewrite, Envoy would
    # see "origin.<domain>" for every request and every HTTPRoute except
    # the health one would 404.
    routes {
      path    = "/{path*}"
      methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

      backend {
        type                       = "HTTP_BACKEND"
        url                        = "https://${local.origin_fqdn}/$${request.path[path]}"
        is_ssl_verify_disabled     = true
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 60
        send_timeout_in_seconds    = 60
      }

      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "Host"
              values    = ["$${request.host}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }
  }
}

# ── origin.<domain> — the one place an LB IP is written (D8 fix) ──────────
resource "oci_dns_rrset" "origin" {
  zone_name_or_id = var.dns_zone_id
  domain          = local.origin_fqdn
  rtype           = "A"

  items {
    domain = local.origin_fqdn
    rtype  = "A"
    rdata  = var.lb_public_ip
    ttl    = 60
  }
}

# edge-probe.<domain> — see the locals block above for why the health
# monitor can't target the gateway's own generated hostname directly.
resource "oci_dns_rrset" "edge_probe" {
  zone_name_or_id = var.dns_zone_id
  domain          = local.edge_probe_fqdn
  rtype           = "CNAME"

  items {
    domain = local.edge_probe_fqdn
    rtype  = "CNAME"
    rdata  = "${oci_apigateway_gateway.edge.hostname}."
    ttl    = 60
  }
}

# ── Health check driving the steering policy's failover decision ─────────
resource "oci_health_checks_http_monitor" "edge" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-hc-edge"
  protocol       = "HTTPS"
  port           = 443
  path           = "/_edge/healthz"
  targets        = [local.edge_probe_fqdn]
  # 60s, not 30s: steering's own ttl is already 60s, so a faster check
  # interval can't produce a faster real-world failover — it only doubles
  # the continuous synthetic-traffic cost (3 vantage points, 24/7) for a
  # lab with negligible real traffic.
  interval_in_seconds = 60
  timeout_in_seconds  = 10
  vantage_point_names = var.health_check_vantage_points
  is_enabled          = true

  # Without this, Terraform's graph has no edge forcing the deployment to
  # exist before the monitor starts probing it (the monitor only
  # references the gateway's hostname, which is known before the
  # deployment converges) — on a first apply that can mean the earliest
  # probes hit a gateway with no live route yet.
  depends_on = [oci_apigateway_deployment.edge]
}

# ── Steering policy: FAILOVER, gateway primary / direct-origin secondary ──
# Rule shape copied verbatim from the working steer-api policy the user
# hand-created (`oci dns steering-policy get`), which is itself the
# documented OCI FAILOVER template shape — not guessed.
resource "oci_dns_steering_policy" "edge" {
  compartment_id          = var.compartment_ocid
  display_name            = "${var.name_prefix}-steer-edge"
  template                = "FAILOVER"
  ttl                     = 60
  health_check_monitor_id = oci_health_checks_http_monitor.edge.id

  answers {
    name        = "gateway"
    rtype       = "CNAME"
    rdata       = "${oci_apigateway_gateway.edge.hostname}."
    pool        = "primary"
    is_disabled = false
  }

  answers {
    name        = "origin-direct"
    rtype       = "CNAME"
    rdata       = "${local.origin_fqdn}."
    pool        = "secondary"
    is_disabled = false
  }

  rules {
    rule_type = "FILTER"
    default_answer_data {
      answer_condition = "answer.isDisabled != true"
      should_keep      = true
    }
  }

  rules {
    rule_type = "HEALTH"
  }

  rules {
    rule_type = "PRIORITY"
    default_answer_data {
      answer_condition = "answer.pool == 'primary'"
      value            = 1
    }
    default_answer_data {
      answer_condition = "answer.pool == 'secondary'"
      value            = 2
    }
  }

  rules {
    rule_type     = "LIMIT"
    default_count = 1
  }
}

resource "oci_dns_steering_policy_attachment" "edge" {
  for_each = toset(var.edge_hostnames)

  display_name       = "${var.name_prefix}-steer-edge-${each.value}"
  steering_policy_id = oci_dns_steering_policy.edge.id
  zone_id            = var.dns_zone_id
  domain_name        = "${each.value}.${var.domain}"
}
