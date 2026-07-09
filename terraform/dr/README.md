# terraform/dr

Phase 14. Same modules as `primary/` (network, cluster-node, lb, iam-ccm), instantiated
with vcn_cidr=10.1.0.0/16, reusing the same compartment + state bucket from `bootstrap/`
but a distinct state key (`dr/terraform.tfstate`).
