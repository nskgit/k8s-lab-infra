# ---------------------------------------------------------------------------
# Node addresses
# ---------------------------------------------------------------------------
output "bastion_public_ip" {
  description = "Reserved public IP of the bastion — SSH entry point for Round 1."
  value       = module.bastion.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node. Reached only via bastion ProxyJump."
  value       = values(module.control_plane.private_ips)[0]
}

output "worker_private_ips" {
  description = "Private IPs of the worker nodes, keyed by name (worker-1, worker-2, ...)."
  value       = module.workers.private_ips
}


# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------
output "lb_public_ip" {
  description = "Public IP of the flexible LB. App is reachable at http://<lb-ip>. In dev/prod: dev.<lb-ip>.nip.io and prod.<lb-ip>.nip.io once Istio is up."
  value       = module.lb.lb_public_ip
}


# ---------------------------------------------------------------------------
# Ready-to-paste SSH commands (bastion ProxyJump into each private node)
# ---------------------------------------------------------------------------
output "ssh_jump_examples" {
  description = "Copy-paste SSH commands into each private node via the bastion. Round 1 manual admin path."
  value = merge(
    {
      "control-plane-1" = "ssh -J opc@${module.bastion.public_ip} opc@${values(module.control_plane.private_ips)[0]}"
    },
    {
      for name, ip in module.workers.private_ips :
      name => "ssh -J opc@${module.bastion.public_ip} opc@${ip}"
    },
  )
}


# ---------------------------------------------------------------------------
# kubectl SSH-tunnel command (Round 1 kubectl access from the Mac)
# ---------------------------------------------------------------------------
output "kubectl_tunnel_command" {
  description = "Open on your Mac, then point kubectl at https://127.0.0.1:6443. Requires 127.0.0.1 in the apiserver cert SANs (locked-decision #23)."
  value       = "ssh -N -L 6443:127.0.0.1:6443 -J opc@${module.bastion.public_ip} opc@${values(module.control_plane.private_ips)[0]}"
}


# ---------------------------------------------------------------------------
# Ansible / CCM inputs (Phase 5)
# ---------------------------------------------------------------------------
output "compartment_ocid" {
  description = "Compartment OCID — used by the OCI CCM cloud-provider.yaml Secret."
  value       = var.compartment_ocid
}

output "vcn_id" {
  description = "VCN OCID — required by CCM to find node subnets and LB backends."
  value       = module.network.vcn_id
}

output "public_subnet_id" {
  description = "Public subnet OCID — where CCM provisions any type=LoadBalancer services (deliberate lab use only)."
  value       = module.network.public_subnet_id
}


# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------
output "edge_gateway_hostname" {
  description = "The API Gateway's own hostname — steering's primary CNAME target."
  value       = module.edge.gateway_hostname
}

output "edge_origin_fqdn" {
  description = "origin.<domain> — the LB-backed FQDN both the gateway backend and steering's secondary answer resolve through. Smoke-test should curl --resolve against this, not a raw IP."
  value       = module.edge.origin_fqdn
}

output "edge_gateway_id" {
  description = "OCID of the API Gateway — edge-cert.yml reads this to know which gateway to point a freshly-rotated certificate at."
  value       = module.edge.gateway_id
}
