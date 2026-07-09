# ============================================================================
# NSGs — per-role firewalls attached to instance vNICs. Security Lists (in
# main.tf) stay near-empty; all rule-based access is defined here.
#
# Rule set = master-plan matrix, pruned for single-cluster:
#   - cp-self rules (6443/2379-2380/10250/4789) removed — same-node loopback
#     never touches the NSG. Re-add at Phase 14 (multi-cp HA/DR).
#   - bastion egress narrowed to jump-host-only (no internet). Phase B
#     self-hosted GitHub runner will need an explicit 443/tcp egress rule.
#   - lb, cp, workers keep general egress (needed for image pulls + Round 1
#     package installs); narrow at Phase 13 hardening.
# ============================================================================

# ============================================================================
# nsg-lb — attached to the public flexible LB (public subnet).
#   IN  : 80,443/tcp  from 0.0.0.0/0      internet HTTP/HTTPS entry
#   OUT : 30080/tcp   to nsg-workers      LB → Istio ingress-gateway HTTP
#         30443/tcp   to nsg-workers      LB → Istio ingress-gateway HTTPS (Phase 6+)
# No catch-all egress — least privilege for the only public-facing NSG.
# ============================================================================
resource "oci_core_network_security_group" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nsg-lb"
}

resource "oci_core_network_security_group_security_rule" "lb_in_http" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Internet → LB:80 (public HTTP entry)"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_in_https" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Internet → LB:443 (public HTTPS entry; listener wired in Phase 6 when Istio TLS lands)"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_out_nodeport_http" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.workers.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "LB → worker NodePort:30080 (Istio ingress-gateway HTTP backend)"

  tcp_options {
    destination_port_range {
      min = 30080
      max = 30080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_out_nodeport_https" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.workers.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "LB → worker NodePort:30443 (Istio ingress-gateway HTTPS backend, Phase 6+)"

  tcp_options {
    destination_port_range {
      min = 30443
      max = 30443
    }
  }
}

# ============================================================================
# nsg-bastion — attached to the jump host (public subnet, reserved public IP).
#   IN  : 22/tcp from your-IP/32           operator SSH entry point
#         (+22/tcp from 0.0.0.0/0 conditional, Phase A only, key-only)
#   OUT : 22/tcp to nsg-cp,nsg-workers     ProxyJump into private nodes
# Pure jump host — no internet egress. Phase B self-hosted runner will need
# an explicit 443/tcp egress rule added; tool installs on the bastion have to
# happen at image-build time or via `scp` from Mac until then.
# ============================================================================
resource "oci_core_network_security_group" "bastion" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nsg-bastion"
}

resource "oci_core_network_security_group_security_rule" "bastion_in_ssh_my_ip" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.my_ip_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Operator public IP → bastion:22 (Round 1 manual admin entry point)"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_in_ssh_public" {
  count = var.allow_bastion_public_ssh ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "0.0.0.0/0 → bastion:22 (Phase A only, key-only auth; toggle off by default)"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_out_ssh_cp" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.cp.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Bastion → cp:22 (ProxyJump for manual admin + SSH-L tunnel host)"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_out_ssh_workers" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.workers.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Bastion → workers:22 (ProxyJump for manual admin, kubeadm join, etc.)"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# ============================================================================
# nsg-cp — attached to the control-plane node (private cp subnet).
#   IN  : 22/tcp    from nsg-bastion       operator SSH via ProxyJump
#         6443/tcp  from nsg-bastion       kubectl direct (or Phase 13 CI runner)
#         6443/tcp  from nsg-workers       worker kubelet → apiserver
#         10250/tcp from nsg-workers       Prometheus (on worker) → cp kubelet scrape
#         5473/tcp  from nsg-workers       Calico typha (hostNetwork:true): worker
#                                          felix → cp typha replica
#         4789/udp  from nsg-workers       Calico VXLAN: worker pod → cp pod
#                                          (CoreDNS + Calico Deployments run on
#                                           cp; they tolerate the control-plane
#                                           taint and get real pod IPs)
#         (cp-self rules pruned — single-cp same-node = loopback)
#   OUT : all → 0.0.0.0/0                  image pulls, kubeadm init, package updates
# ============================================================================
resource "oci_core_network_security_group" "cp" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nsg-cp"
}

resource "oci_core_network_security_group_security_rule" "cp_in_ssh_bastion" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.bastion.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Bastion → cp:22 (Round 1 manual admin via ProxyJump)"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_in_apiserver_bastion" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.bastion.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Bastion → cp apiserver:6443 (kubectl from bastion, or SSH-L single-hop tunnel exit; Phase 13 CI runner)"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_in_apiserver_workers" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker kubelet → cp apiserver:6443 (node register, heartbeats, watch/list)"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_in_kubelet_workers" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Prometheus (on worker) → cp kubelet:10250 (cAdvisor + node metrics scrape)"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

# calico-typha uses `hostNetwork: true` (Tigera Operator default), so its "pod
# IPs" are node IPs. felix on each calico-node discovers typha's endpoint IPs
# directly (bypasses the Service) and connects on TCP 5473. Without these three
# 5473 rules (worker→cp, worker→worker, cp→worker), cross-node felix→typha
# connects silently timeout, leaving calico-node stuck in 0/1 Ready with felix
# logs saying "Failed to connect to typha endpoint ... i/o timeout".
# Discovered 2026-07-09 Phase 4 when worker-2's calico-node had been 10h stuck.
resource "oci_core_network_security_group_security_rule" "cp_in_typha_workers" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Calico typha (hostNetwork:true): worker felix → cp typha replica on TCP 5473. Without this, cross-node felix→typha silently times out and calico-node stays 0/1 Ready."

  tcp_options {
    destination_port_range {
      min = 5473
      max = 5473
    }
  }
}

# cp_in_vxlan_workers: RE-ADDED 2026-07-09 after Phase 2 DNS test failed.
# Earlier prune ("nothing on cp has a pod IP") was wrong — Deployments that
# tolerate the control-plane taint (CoreDNS, calico-typha, calico-kube-
# controllers, calico-apiserver, tigera-operator) land on cp with real pod IPs
# in the 10.244.0.0/16 pool. Any worker pod resolving kubernetes.default via
# CoreDNS needs to reach those pod IPs — Calico encapsulates as worker-node-IP
# → cp-node-IP UDP 4789. Blocking this rule silently breaks in-cluster DNS.
resource "oci_core_network_security_group_security_rule" "cp_in_vxlan_workers" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Calico VXLAN: worker pod → cp pod (CoreDNS/typha/etc). Encaped as worker-node → cp-node UDP 4789."

  udp_options {
    destination_port_range {
      min = 4789
      max = 4789
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_out_all" {
  network_security_group_id = oci_core_network_security_group.cp.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "cp egress. NAT: registry.k8s.io (kubeadm init images), yum.oracle.com (containerd), raw.githubusercontent.com (Calico). SGW: OCIR/Object Storage/Block Volume. DNS. Narrow at Phase 13. Details in section header."
}

# ============================================================================
# nsg-workers — attached to both worker nodes (private workers subnet).
#   IN  : 22/tcp    from nsg-bastion       operator SSH via ProxyJump
#         10250/tcp from nsg-cp            apiserver → worker kubelet (exec/logs/attach proxy)
#         10250/tcp from nsg-workers       Prometheus (worker A) → worker B kubelet scrape
#         30080/tcp from nsg-lb            LB → Istio ingress-gateway HTTP
#         30443/tcp from nsg-lb            LB → Istio ingress-gateway HTTPS (Phase 6+)
#         5473/tcp  from nsg-cp            Calico typha (hostNetwork:true): cp
#                                          felix → worker typha replica (defensive)
#         5473/tcp  from nsg-workers       Calico typha (hostNetwork:true): worker
#                                          felix → other-worker typha replica
#         4789/udp  from nsg-cp            Calico VXLAN cp pod → worker pod
#         4789/udp  from nsg-workers       Calico VXLAN worker A pod → worker B pod
#   OUT : all → 0.0.0.0/0
#         Intra-cluster: cp:6443 (kubeadm join discovery + TLS bootstrap CSR
#                                 submission; kubelet↔apiserver register/heart-
#                                 beat/watch; kube-proxy watches Services)
#         Public via NAT GW: registry.k8s.io (kubeadm join: pause + kube-proxy
#                                             images), docker.io/quay.io (cal-
#                                             ico-node DS, Istio sidecars,
#                                             k-p-s agents pre-mirror), yum.
#                                             oracle.com (dnf: containerd,
#                                             kernel-modules, updates), raw.
#                                             githubusercontent.com (Calico
#                                             manifest fetch during Round 1)
#         Via Service GW: OCIR (Phase 9+ user/platform images), Object Storage
#                          (Phase 12+ backups), Block Volume API (CSI dynamic
#                          provisioning)
#         DNS to VCN resolver
# ============================================================================
resource "oci_core_network_security_group" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nsg-workers"
}

resource "oci_core_network_security_group_security_rule" "workers_in_ssh_bastion" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.bastion.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Bastion → worker:22 (Round 1 manual admin via ProxyJump)"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_kubelet_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.cp.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "apiserver (cp) → worker kubelet:10250 (kubectl exec/logs/portforward/attach proxy)"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_kubelet_self" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Prometheus (worker A) → worker B kubelet:10250 (cross-worker scrape); same-node SNAT'd by Calico natOutgoing hits here too"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_nodeport_http" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "LB → worker:30080 (Istio ingress-gateway HTTP NodePort)"

  tcp_options {
    destination_port_range {
      min = 30080
      max = 30080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_nodeport_https" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "LB → worker:30443 (Istio ingress-gateway HTTPS NodePort, Phase 6+)"

  tcp_options {
    destination_port_range {
      min = 30443
      max = 30443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_vxlan_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.cp.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Calico VXLAN: cp pod → worker pod, encapsulated as node → node UDP 4789"

  udp_options {
    destination_port_range {
      min = 4789
      max = 4789
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_vxlan_self" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Calico VXLAN: worker A pod → worker B pod, encapsulated as node → node UDP 4789"

  udp_options {
    destination_port_range {
      min = 4789
      max = 4789
    }
  }
}

# Calico typha reachability from worker felix — companion to cp_in_typha_workers.
# calico-typha is a Deployment with hostNetwork:true; the operator schedules
# replicas across cp AND workers. worker-2's felix must reach the typha replica
# that landed on worker-1 (workers_in_typha_self), and cp's felix must be able
# to reach a worker's typha replica if cp's local one dies (workers_in_typha_cp,
# defensive).
resource "oci_core_network_security_group_security_rule" "workers_in_typha_self" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Calico typha (hostNetwork:true): worker felix → other-worker typha replica on TCP 5473. Without this, calico-node whose typha lives on the other worker sticks in 0/1 Ready."

  tcp_options {
    destination_port_range {
      min = 5473
      max = 5473
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_in_typha_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.cp.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Calico typha (hostNetwork:true): cp felix → worker typha replica on TCP 5473. Defensive (used only if cp's local typha replica fails and cp needs to reach a worker's)."

  tcp_options {
    destination_port_range {
      min = 5473
      max = 5473
    }
  }
}

# kubeadm join specifically needs: (1) cp:6443 for discovery + TLS bootstrap
# CSR submission (contact the apiserver, fetch cluster-info, submit a CSR,
# retrieve signed kubelet cert); (2) registry.k8s.io:443 for pause + kube-proxy
# image pulls (kube-proxy DS spins up on the new worker right after join);
# (3) DNS to resolve registry.k8s.io; (4) docker.io/quay.io:443 shortly after
# for the calico-node DS image on first pod start. All four ride this one rule.
resource "oci_core_network_security_group_security_rule" "workers_out_all" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "worker egress. Intra: cp:6443 (kubelet, kubeadm join). NAT: registry.k8s.io, docker.io, quay.io, yum.oracle.com, raw.githubusercontent.com. SGW: OCIR/Object Storage/Block Volume. DNS. Details in section header."
}
