data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
  # FROZEN independent of name_prefix (2026-09-08 rename incident): dns_label
  # is immutable on OCI VCNs — changing it forces full VCN replacement,
  # cascading into every subnet/NSG/instance attached (proven: a plan showed
  # 58 destroy + 58 create when this was still derived from name_prefix).
  # It's also purely internal (forms *.k8slab.oraclevcn.com FQDNs used by
  # the private DNS zones) — never reader-facing, so nothing is lost by
  # keeping the original value forever.
  dns_label = var.vcn_dns_label
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-natgw"
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-sgw"

  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

# ---------------------------------------------------------------------------
# Route tables — public: 0.0.0.0/0 -> IGW. Private (shared by cp+workers):
# 0.0.0.0/0 -> NAT GW, Oracle Services Network CIDR -> Service Gateway.
# ---------------------------------------------------------------------------
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-rt-public"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-rt-private"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

# ---------------------------------------------------------------------------
# Default security list — left near-empty per the master plan ("Security
# Lists kept near-empty; all rules in NSGs"). Egress-all + ICMP-only ingress
# (destination-unreachable/fragmentation-needed, for path MTU discovery).
# ---------------------------------------------------------------------------
resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  compartment_id             = var.compartment_ocid
  display_name               = "${var.name_prefix}-default-sl"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

# ---------------------------------------------------------------------------
# Subnets — regional (no availability_domain). cp/workers are private.
# ---------------------------------------------------------------------------
resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.name_prefix}-subnet-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_default_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "cp" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.cp_subnet_cidr
  display_name               = "${var.name_prefix}-subnet-cp"
  dns_label                  = "cp"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_default_security_list.this.id]
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_subnet" "workers" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.worker_subnet_cidr
  display_name               = "${var.name_prefix}-subnet-workers"
  dns_label                  = "workers"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_default_security_list.this.id]
  prohibit_public_ip_on_vnic = true
}
