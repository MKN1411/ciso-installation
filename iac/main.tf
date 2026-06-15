# ==============================================================================
# Terraform Main Configuration: OCI GRC Infrastructure
# ==============================================================================

terraform {
  required_version = ">= 1.2.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }
}

provider "oci" {
  region           = var.region
}

# 1. Virtual Cloud Network (VCN)
resource "oci_core_vcn" "grc_vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = "grc_vcn"
  dns_label      = "grcvcn"
}

# 2. NAT Gateway (For secure outbound VM internet access)
resource "oci_core_nat_gateway" "grc_nat_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.grc_vcn.id
  display_name   = "grc_nat_gateway"
}

# 3. Route Table (Routet den ausgehenden Datenverkehr über das NAT Gateway)
resource "oci_core_route_table" "private_route_table" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.grc_vcn.id
  display_name   = "private_route_table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.grc_nat_gateway.id
  }
}

# 4. Security List (Firewall-Regeln für das private Subnetz)
resource "oci_core_security_list" "private_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.grc_vcn.id
  display_name   = "private_security_list"

  # Egress Rules (Ausgehender Verkehr: Erlaubt VM Updates & Cloudflare Verbindung)
  egress_security_rules {
    destination      = "0.0.0.0/0"
    protocol         = "all" # Erlaubt jeglichen ausgehenden Verkehr über das NAT Gateway
    destination_type = "CIDR_BLOCK"
  }

  # Ingress Rules (Eingehender Verkehr: Blockiert das gesamte Internet)
  # Erlaubt SSH (Port 22) AUSSCHLIESSLICH aus dem VCN Adressbereich (wird von Bastion genutzt)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 22
      max = 22
    }
  }
}

# 5. Private Subnet (Für die GRC-Plattform VM)
resource "oci_core_subnet" "private_subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.grc_vcn.id
  cidr_block        = var.private_subnet_cidr
  display_name      = "private_subnet"
  dns_label         = "private"
  route_table_id    = oci_core_route_table.private_route_table.id
  security_list_ids = [oci_core_security_list.private_security_list.id]
  
  # Verhindert Zuweisung einer öffentlichen IP
  prohibit_public_ip_on_vnic = true
}

# 6. Extra Subnet (Für spätere Erweiterungen)
resource "oci_core_subnet" "extra_subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.grc_vcn.id
  cidr_block        = var.extra_subnet_cidr
  display_name      = "extra_subnet"
  dns_label         = "extra"
  route_table_id    = oci_core_route_table.private_route_table.id
  security_list_ids = [oci_core_security_list.private_security_list.id]
  
  prohibit_public_ip_on_vnic = true
}

# 7. Compute Instance (CISO Assistant Server - ARM Ampere VM)
resource "oci_core_instance" "grc_instance" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  shape               = var.instance_shape
  display_name        = "ciso-assistant-vps"

  dynamic "shape_config" {
    for_each = length(regexall("Flex", var.instance_shape)) > 0 ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gbs
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private_subnet.id
    display_name     = "primaryvnic"
    assign_public_ip = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # Injiziert das Cloud-Init Skript zur automatischen Docker- & CISO Assistant Installation
    user_data           = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      github_repo       = var.github_repo
      github_token      = var.github_token
      notification_email = var.notification_email
    }))
  }

  source_details {
    source_type = "image"
    # Findet automatisch das aktuelle Ubuntu Image
    source_id   = data.oci_core_images.ubuntu_images.images[0].id
  }
}

# 8. OCI Bastion Service (Erlaubt sicheren SSH-Zugriff ohne offene Ports im Internet)
resource "oci_bastion_bastion" "grc_bastion" {
  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_ocid
  target_subnet_id             = oci_core_subnet.private_subnet.id
  client_cidr_block_allow_list = ["0.0.0.0/0"] # Zugriff auf Bastion wird durch OCI IAM Keys geschützt
  name                         = "grc_bastion"
  max_session_ttl_in_seconds   = 10800 # 3 Stunden maximal pro Session
}

# Data Sources zur Ermittlung von Regionen-Details und Images
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
}
