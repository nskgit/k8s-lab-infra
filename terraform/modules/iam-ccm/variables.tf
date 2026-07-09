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
  default = "k8s-lab"
}
