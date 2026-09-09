# Copy to terraform.tfvars (gitignored) and fill in real values before plan/apply.

# ---- Identity ----
tenancy_ocid = "ocid1.tenancy.oc1..aaaaaaaaytt5po67h3ubkw2qc3zdvj6xgnlotcwqwcanlycysrzicesyesia"
region       = "us-ashburn-1"

# ---- Compartment (from bootstrap output: compartment_ocid) ----
compartment_ocid = "ocid1.compartment.oc1..aaaaaaaaflb6frgnzi5st4cyib4ephtvixgunefbs5bftjt6kzv5v5xlfcra"
compartment_name = "platform-engine"

# ---- Naming ----
name_prefix = "platform-engine"

# ---- Network ----
vcn_cidr           = "10.0.0.0/16"
public_subnet_cidr = "10.0.0.0/24"
cp_subnet_cidr     = "10.0.1.0/24"
worker_subnet_cidr = "10.0.2.0/24"

# Your public IP as /32 — the ONLY source allowed to SSH the bastion.
# Get it once with: curl -s ifconfig.me
my_ip_cidr = "120.56.238.120/32"

# Set true only when temporarily using the Phase-A hosted CI runner path.
allow_bastion_public_ssh = true

# ---- Edge ----
domain      = "satheshkumarnapoleon.site"
dns_zone_id = "ocid1.dns-zone.oc1..aaaaaaaacu5xxgy6uljvyyykdsqjkbf3ifmcuk3ws6mdonqnud526p2aiv3a"
# edge_hostnames defaults to every existing HTTPRoute host — override only
# when adding/removing a public service.
# edge_certificate_pem / edge_certificate_key_pem are REQUIRED and have no
# default on purpose — never put real cert/key material in this committed
# file. CD supplies them as TF_VAR_edge_certificate_pem /
# TF_VAR_edge_certificate_key_pem from GitHub secrets; for a local plan,
# export the same env vars from your own copy of the material.

# ---- Access ----
# Contents of ~/.ssh/k8s_lab_ed25519.pub — trusted by bastion/cp/workers.
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOg+3YijPQ77Sq0TB3MxgbxjTALYLViNQB6WUZZyVxHH k8s-lab" # trailing label FROZEN — the OCI provider treats any change to instance "metadata" (which carries this) as forcing replacement, even though the label itself is cosmetic and unused by cloud-init after first boot

# ---- Availability domain ----
# 0-indexed. Change to 1 or 2 if AD 0 doesn't have Always-Free A1.Flex capacity.
availability_domain_index = 0

# ---- Shapes / sizing (Always Free defaults; override only if paying) ----
# bastion_shape           = "VM.Standard.E2.1.Micro"
# cp_shape                = "VM.Standard.A1.Flex"
# cp_ocpus                = 2
# cp_memory_in_gbs        = 8
# worker_shape            = "VM.Standard.A1.Flex"
# worker_count            = 2
# worker_ocpus            = 1
# worker_memory_in_gbs    = 8
# boot_volume_size_in_gbs = 50

# ---- LB ----
# nodeport_http = 30080
