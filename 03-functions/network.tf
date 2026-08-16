# ================================================================================
# Networking
# ================================================================================
# Creates a minimal VCN with a single public subnet used by both OCI Functions
# (for outbound connectivity to OCI services) and the API Gateway (for inbound
# HTTPS traffic).  A Service Gateway is intentionally omitted in favour of an
# Internet Gateway to keep the topology simple for this demo.
# ================================================================================

# --------------------------------------------------------------------------------
# VCN
# --------------------------------------------------------------------------------
resource "oci_core_vcn" "notes" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "notes-vcn"
  dns_label      = "notesvn"
}

# --------------------------------------------------------------------------------
# Internet Gateway — default route for public subnet egress
# --------------------------------------------------------------------------------
resource "oci_core_internet_gateway" "notes" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.notes.id
  display_name   = "notes-igw"
  enabled        = true
}

# --------------------------------------------------------------------------------
# Route Table — default route to the internet gateway
# --------------------------------------------------------------------------------
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.notes.id
  display_name   = "notes-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.notes.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

# --------------------------------------------------------------------------------
# Security List
# --------------------------------------------------------------------------------
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.notes.id
  display_name   = "notes-public-sl"

  # Allow all egress — Functions need to reach OCIR (image pull) and OCI NoSQL.
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }

  # Allow HTTPS inbound — API Gateway needs port 443 open to serve traffic.
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 443
      max = 443
    }
  }
}

# --------------------------------------------------------------------------------
# Public Subnet — shared by API Gateway and the Functions Application
# --------------------------------------------------------------------------------
resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.notes.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "notes-public-subnet"
  dns_label         = "notespub"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]

  # Public subnet — VNICs in this subnet receive public IPs.
  prohibit_public_ip_on_vnic = false
}
