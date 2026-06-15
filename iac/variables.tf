# ==============================================================================
# Terraform Variables: OCI GRC Infrastructure
# ==============================================================================


variable "region" {
  type        = string
  description = "The OCI Region (e.g., eu-frankfurt-1)."
  default     = "eu-frankfurt-1"
}

variable "compartment_ocid" {
  type        = string
  description = "The OCID of the Compartment where resources will be created."
}

variable "ssh_public_key" {
  type        = string
  description = "The SSH Public Key to be injected into the VM for SSH authentication."
}

variable "instance_shape" {
  type        = string
  description = "The compute instance shape (Default: Ampere A1 Always Free Shape)."
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  type        = number
  description = "Number of OCPUs for the VM (Only applicable for Flex shapes)."
  default     = 2
}

variable "instance_memory_gbs" {
  type        = number
  description = "Memory in GBs for the VM (Only applicable for Flex shapes)."
  default     = 8
}

variable "availability_domain_index" {
  type        = number
  description = "Index of the OCI Availability Domain to deploy the VM in (0 = AD-1, 1 = AD-2, 2 = AD-3)."
  default     = 1
}

variable "vcn_cidr" {
  type        = string
  description = "The CIDR block for the VCN."
  default     = "10.250.250.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "The CIDR block for the Private VM Subnet."
  default     = "10.250.250.0/28"
}

variable "extra_subnet_cidr" {
  type        = string
  description = "The CIDR block for the Extra Subnet."
  default     = "10.250.250.16/29"
}

variable "github_repo" {
  type        = string
  description = "The owner/repository of the user's fork (e.g., username/ciso-installation)."
  default     = ""
}

variable "github_token" {
  type        = string
  description = "The GitHub PAT or short-lived token to update status."
  default     = ""
  sensitive   = true
}

variable "notification_email" {
  type        = string
  description = "Email address for Cloudflare Tunnel URL notifications (Community version: sender = receiver)."
  default     = ""
}

