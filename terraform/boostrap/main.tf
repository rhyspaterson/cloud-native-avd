# Configure the providers.
terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.22"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.2.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 4.25"
    }
  }
  required_version = ">= 1.2.0"
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
}

provider "github" {
  owner = var.repo_owner
  token = var.github_pat
}

# Store our current Azure client configuration in state.
data "azuread_client_config" "current" {}
data "azurerm_client_config" "current" {}

resource "azuread_application" "app" {
  display_name = "${var.prefix}-app"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "sp" {
  application_id = azuread_application.app.application_id
  owners         = [data.azuread_client_config.current.object_id]
}

resource "azurerm_resource_group" "rg" {
  name     = var.prefix
  location = var.default_location
}

# Generate random text for a unique storage account.
resource "random_id" "randomId" {
  keepers = {
    # Generate a new ID only when a new resource group is defined.
    resource_group = azurerm_resource_group.rg.name
  }
  byte_length = 8
}

# Create storage account for tf state, boot diagnostics, and anything else we might need.
resource "azurerm_storage_account" "storageaccount" {
  name                     = "avd${random_id.randomId.hex}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = "australiaeast"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags = {
    terraform = "cn-avd-state"
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "terraform-state"
  storage_account_name  = azurerm_storage_account.storageaccount.name
  container_access_type = "private"
}

resource "azurerm_role_assignment" "iam" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.sp.id
}

# Deploy our OIDC credentials.
resource "azuread_application_federated_identity_credential" "oidc" {
  application_object_id = azuread_application.app.object_id
  display_name          = "${var.prefix}-OIDC"
  description           = "Deployments for repo:${var.repo_owner}/${var.repo_name}:environment:prod"
  audiences             = ["api://AzureADTokenExchange"]
  issuer                = "https://token.actions.githubusercontent.com"
  subject               = "repo:${var.repo_owner}/${var.repo_name}:ref:refs/heads/main"
}

# We need our public key to encrypt the secrets.
data "github_actions_public_key" "repo_public_key" {
  repository = var.repo_name
}

resource "github_actions_secret" "secret_azure_tenant_id" {
  repository      = var.repo_name
  secret_name     = "AZURE_TENANT_ID"
  plaintext_value = var.tenant_id
}

resource "github_actions_secret" "secret_azure_subscription_id" {
  repository      = var.repo_name
  secret_name     = "AZURE_SUBSCRIPTION_ID"
  plaintext_value = var.subscription_id
}

resource "github_actions_secret" "secret_azure_client_id" {
  repository      = var.repo_name
  secret_name     = "AZURE_CLIENT_ID"
  plaintext_value = azuread_application.app.application_id
}

resource "github_actions_secret" "secret_azure_state_storage_account_name" {
  repository      = var.repo_name
  secret_name     = "AZURE_STATE_STORAGE_ACCOUNT_NAME"
  plaintext_value = azurerm_storage_account.storageaccount.name
}

resource "github_actions_secret" "secret_azure_state_container_name" {
  repository      = var.repo_name
  secret_name     = "AZURE_STATE_CONTAINER_NAME"
  plaintext_value = azurerm_storage_container.state.name
}

resource "github_actions_secret" "secret_azure_resource_group_name" {
  repository      = var.repo_name
  secret_name     = "AZURE_RESOURCE_GROUP_NAME"
  plaintext_value = azurerm_resource_group.rg.name
}