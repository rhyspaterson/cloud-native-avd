variable "prefix" {
  type        = string
  default     = "cn-avd"
  description = "the prefix used in naming our resources"
}

variable "preferred_location" {
  type        = string
  default     = "australia east"
  description = "the default/preferred location for our resources"
}

variable "avd_location" {
  type        = string
  default     = "westus2"
  description = "the constrained location to deploy the AVD PaaS services to"
}

variable "avd_vm_count" {
  default     = "1"
  description = "the number of virtual machines to create"
}

variable "avd_vm_size" {
  default     = "Standard_B4ms"
  description = "the virutal machine size to leverage"
}

variable "avd_display_name" {
  default     = "Cloud Native Virtual Desktop"
  description = "the display name of the desktop presented to end users"
}

variable "avd_workspace_display_name" {
  default     = "Cloud Native Workspace"
  description = "the display name of the workspace presented to end users"
}