# ============================================================================
# edge — public DNS steering -> API Gateway -> LB -> Istio (2026-09-09).
#
# Request path this module builds:
#   client -> DNS steering (FAILOVER) -> primary: CNAME to this API Gateway
#                                      -> secondary: CNAME to origin.<domain>
#                                         (a plain A record at the LB, i.e.
#                                         the OLD direct path, kept as the
#                                         "dummy"/bypass answer)
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
# Why one A record (origin.<domain>) instead of hardcoding the LB IP in
# two places: this is also the D8 fix (docs/PHASES-4-15-EXECUTION-PLAN.md)
# — a future LB replacement only needs this one record updated, and
# nothing above it (the steering policy's secondary answer, the gateway's
# backend URL) needs to change.
# ============================================================================

# The oracle/oci provider has no data source for an existing DNS zone (only
# the resource, for creating one) — the zone OCID comes in as a variable,
# same convention this repo already uses for compartment_ocid etc.

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
        url                        = "https://origin.${var.domain}/_edge/healthz"
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
              values    = ["origin.${var.domain}"]
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
        url                        = "https://origin.${var.domain}/$${request.path[path]}"
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
  domain          = "origin.${var.domain}"
  rtype           = "A"

  items {
    domain = "origin.${var.domain}"
    rtype  = "A"
    rdata  = var.lb_public_ip
    ttl    = 60
  }
}

# ── Health check driving the steering policy's failover decision ─────────
resource "oci_health_checks_http_monitor" "edge" {
  compartment_id      = var.compartment_ocid
  display_name        = "${var.name_prefix}-hc-edge"
  protocol            = "HTTPS"
  port                = 443
  path                = "/_edge/healthz"
  targets             = [oci_apigateway_gateway.edge.hostname]
  interval_in_seconds = 30
  timeout_in_seconds  = 10
  vantage_point_names = var.health_check_vantage_points
  is_enabled          = true
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
    rdata       = "origin.${var.domain}."
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
