variable "tenancy_ocid" {
  type        = string
  description = "Dynamic groups always live at the tenancy root."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment the dynamic group's matching rule scopes to, and the policy applies in."
}

variable "compartment_name" {
  type        = string
  description = "Compartment name, used in the policy statement's 'in compartment <name>' clause."
}

variable "name_prefix" {
  type    = string
  default = "platform-engine"
}

variable "frozen_prefix" {
  type        = string
  description = "Prefix for the dynamic-group/policy NAMES only — immutable in OCI (any change forces destroy+recreate, briefly interrupting CCM/CSI instance-principal auth). Deliberately decoupled from name_prefix. Internal identifier, never reader-facing."
  default     = "k8s-lab"
}
