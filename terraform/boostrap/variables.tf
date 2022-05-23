variable "repo_owner" {
  type        = string
  description = "the owner of the github repo"
}

variable "repo_name" {
  type        = string
  description = "the name of the github repo to write out secrets to"
}

variable "github_pat" {
  type        = string
  description = "a temporary github personal access token used to bootstrap the actions workflow"
}

variable "subscription_id" {
  type        = string
  description = "the azure subscription we will deploy into"
}

variable "tenant_id" {
  type        = string
  description = "the azure directory/tenant associated with the subscription"
}

variable "prefix" {
  type        = string
  default     = "CN-AVD"
  description = "the prefix used in naming our resources"
}

variable "default_location" {
  type        = string
  default     = "australia east"
  description = "the default/preferred location for our resources"
}