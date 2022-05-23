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
    time = {
      source  = "hashicorp/time"
      version = ">= 0.7.2"
    }
  }
  required_version = ">= 1.2.0"
  backend "azurerm" {}
}

provider "azurerm" {
  skip_provider_registration = true
  use_oidc                   = true
  features {}
}

provider "azuread" {}

# Our resource group.
data "azurerm_resource_group" "rg" {
  name = var.prefix
}

# Because our storage account name is dynamically generated via the bootstrap, we don't know it's name.
# We could pull it from the GitHub secret, but then we're introducing rigidity directly into our HCL.
# Thus we search for storage account via the generic resource data source, filtering for resources in our 
# resource group that have the tag we applied during bootstrapping, and the type of storageAccounts.
data "azurerm_resources" "storage" {
  resource_group_name = data.azurerm_resource_group.rg.name
  type                = "Microsoft.Storage/storageAccounts"
  required_tags = {
    terraform = "cn-avd-state"
  }
}

# Seems as though we get a list of objects returned even with only one storageAccount.
# We're only expecting one back, so let's grab it. What could go wrong!
data "azurerm_storage_account" "storage" {
  name                = data.azurerm_resources.storage.resources[0].name
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_log_analytics_workspace" "law" {
  name                       = "${var.prefix}-law"
  location                   = var.preferred_location
  resource_group_name        = data.azurerm_resource_group.rg.name
  sku                        = "PerGB2018"
  retention_in_days          = "30"
  internet_ingestion_enabled = true
  internet_query_enabled     = true
}

# Add our solutions. The solution_name must match the Azure resource solution name.
resource "azurerm_log_analytics_solution" "vminsights" {
  solution_name         = "VMInsights"
  location              = var.preferred_location
  resource_group_name   = data.azurerm_resource_group.rg.name
  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/VMInsights"
  }
}

resource "azurerm_log_analytics_solution" "changetracking" {
  solution_name         = "ChangeTracking"
  location              = var.preferred_location
  resource_group_name   = data.azurerm_resource_group.rg.name
  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ChangeTracking"
  }
}

resource "azurerm_log_analytics_solution" "updates" {
  solution_name         = "Updates"
  location              = var.preferred_location
  resource_group_name   = data.azurerm_resource_group.rg.name
  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/Updates"
  }
}

# Provision our automation account for update management.
resource "azurerm_automation_account" "automation" {
  name                = "${var.prefix}-automation-account"
  location            = var.preferred_location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku_name            = "Basic"
}

resource "azurerm_log_analytics_linked_service" "link" {
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  read_access_id      = azurerm_automation_account.automation.id
}

# Provision our AVD workspace.
resource "azurerm_virtual_desktop_workspace" "workspace" {
  name                = var.avd_workspace_display_name
  resource_group_name = var.prefix
  location            = var.avd_location
}

# Provision our AVD host pool.
# To do: add scheduled agent updates once available in the provider.
resource "azurerm_virtual_desktop_host_pool" "hostpool" {
  name                  = "${var.prefix}-host-pool"
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = azurerm_virtual_desktop_workspace.workspace.location
  custom_rdp_properties = "audiocapturemode:i:1;audiomode:i:0;targetisaadjoined:i:1;"
  type                  = "Pooled"
  load_balancer_type    = "BreadthFirst"
  start_vm_on_connect   = true
}

# Provision our desktop application group.
resource "azurerm_virtual_desktop_application_group" "dag" {
  name                         = "${var.prefix}-dag"
  resource_group_name          = data.azurerm_resource_group.rg.name
  location                     = azurerm_virtual_desktop_workspace.workspace.location
  type                         = "Desktop"
  default_desktop_display_name = var.avd_display_name
  host_pool_id                 = azurerm_virtual_desktop_host_pool.hostpool.id
  depends_on                   = [azurerm_virtual_desktop_host_pool.hostpool, azurerm_virtual_desktop_workspace.workspace]
}

# Associate our workspace and desktop application group.
resource "azurerm_virtual_desktop_workspace_application_group_association" "ws-dag" {
  application_group_id = azurerm_virtual_desktop_application_group.dag.id
  workspace_id         = azurerm_virtual_desktop_workspace.workspace.id
}

# Create the registration token to authorise new session hosts into the host pool.
resource "time_rotating" "avd_registration_expiration" {
  # Must be between 1 hour and 30 days.
  rotation_days = 30
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "token" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.hostpool.id
  expiration_date = time_rotating.avd_registration_expiration.rotation_rfc3339
}

# Future proofing for additional session hosts.
resource "azurerm_availability_set" "avd" {
  name                         = "${var.prefix}-availability-set"
  location                     = var.preferred_location
  resource_group_name          = data.azurerm_resource_group.rg.name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
}

# Create the vnet for our session hosts to reside in.
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.8.0/24"]
  location            = var.preferred_location
}

# Create the subnet for out session hosts vnics to reside in.
resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-session-hosts"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.8.0/26"]
}

# Add a direct route for KMS activation.
# https://docs.microsoft.com/en-us/troubleshoot/azure/virtual-machines/custom-routes-enable-kms-activation
resource "azurerm_route_table" "session_hosts" {
  name                = "${var.prefix}-session-hosts-route-table"
  location            = var.preferred_location
  resource_group_name = data.azurerm_resource_group.rg.name

  route {
    name           = "DirectRouteToKMS"
    address_prefix = "23.102.135.246/32"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_subnet_route_table_association" "session_hosts" {
  subnet_id      = azurerm_subnet.subnet.id
  route_table_id = azurerm_route_table.session_hosts.id
}

# Create the vnics for our session hosts.
resource "azurerm_network_interface" "nic" {
  name                = "${var.prefix}-vm-${count.index + 1}-nic-${count.index + 1}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.preferred_location
  count               = var.avd_vm_count

  ip_configuration {
    name                          = "webipconfig${count.index}"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "random_password" "password" {
  length  = 20
  special = false
}

# Create the session host.
resource "azurerm_windows_virtual_machine" "vm" {
  depends_on = [
    azurerm_network_interface.nic
  ]
  name                       = "${var.prefix}-vm-${count.index + 1}"
  computer_name              = "${var.prefix}-vm-${count.index + 1}"
  location                   = var.preferred_location
  resource_group_name        = data.azurerm_resource_group.rg.name
  size                       = var.avd_vm_size
  network_interface_ids      = ["${element(azurerm_network_interface.nic.*.id, count.index)}"]
  count                      = var.avd_vm_count
  vtpm_enabled               = true
  secure_boot_enabled        = true
  admin_username             = "localadmin"
  admin_password             = random_password.password.result
  enable_automatic_updates   = true
  provision_vm_agent         = true
  encryption_at_host_enabled = true
  availability_set_id        = azurerm_availability_set.avd.id

  source_image_reference {
    publisher = "microsoftwindowsdesktop"
    offer     = "office-365"
    sku       = "win11-21h2-avd-m365"
    version   = "latest"
  }

  os_disk {
    name                 = "${var.prefix}-vm-${count.index + 1}-disk-${count.index + 1}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {
    storage_account_uri = data.azurerm_storage_account.storage.primary_blob_endpoint
  }

  # Used to bootstrap the virtual machine on launch. Great for configuring things like root certificates required for
  # initial network communication requirements, and any other important non-Intune options.
  # Stores the file at: c:/azuredata/customdata.bin.
  custom_data = filebase64("${path.root}/bootstrap.ps1")
}

# Join to AAD. For issues, we can look at logs for the extension agent here:
#   gci C:\WindowsAzure\Logs\Microsoft.Azure.ActiveDirectory.AADLoginForWindows -Recurse
# Other things worth noting:
#   - https://docs.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-ad-joined-vm#deploy-azure-ad-joined-vms
#   - https://docs.microsoft.com/en-us/azure/active-directory/devices/howto-vm-sign-in-azure-ad-windows#mfa-sign-in-method-required

resource "azurerm_virtual_machine_extension" "aad" {
  name                       = "ext-AADLoginForWindows"
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  count                      = var.avd_vm_count
  settings                   = <<-SETTINGS
    {
      "mdmId": "0000000a-0000-0000-c000-000000000000"
    }
    SETTINGS  
}
resource "azurerm_virtual_machine_extension" "monitoring" {
  count                      = var.avd_vm_count
  name                       = "ext-MicrosoftMonitoringAgent"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.EnterpriseCloud.Monitoring"
  type                       = "MicrosoftMonitoringAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  settings                   = <<SETTINGS
    {
        "workspaceId": "${azurerm_log_analytics_workspace.law.workspace_id}"
    }
  SETTINGS
  protected_settings         = <<PROTECTED_SETTINGS
    {
      "workspaceKey": "${azurerm_log_analytics_workspace.law.primary_shared_key}"
    }
  PROTECTED_SETTINGS  
}

resource "azurerm_virtual_machine_extension" "da" {
  count                      = var.avd_vm_count
  name                       = "ext-DependencyAgentWindows"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Azure.Monitoring.DependencyAgent"
  type                       = "DependencyAgentWindows"
  type_handler_version       = "9.10"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}
resource "azurerm_virtual_machine_extension" "guesthealth" {
  count                      = var.avd_vm_count
  name                       = "ext-GuestHealth"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Azure.Monitor.VirtualMachines.GuestHealth"
  type                       = "GuestHealthWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = false
}

resource "azurerm_virtual_machine_extension" "azuremonitor" {
  count                      = var.avd_vm_count
  name                       = "ext-AzureMonitor"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.4"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}

resource "azurerm_virtual_machine_extension" "guestattestation" {
  count                      = var.avd_vm_count
  name                       = "ext-GuestAttestation"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Azure.Security.WindowsAttestation"
  type                       = "GuestAttestation"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = false
}

resource "azurerm_virtual_machine_extension" "guestconfiguration" {
  count                      = var.avd_vm_count
  name                       = "ext-GuestConfiguration"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.GuestConfiguration"
  type                       = "ConfigurationforWindows"
  type_handler_version       = "1.29"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}

resource "azurerm_virtual_machine_extension" "networkwatcher" {
  count                      = var.avd_vm_count
  name                       = "ext-NetworkWatcher"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Azure.NetworkWatcher"
  type                       = "NetworkWatcherAgentWindows"
  type_handler_version       = "1.4"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = false
}

resource "azurerm_virtual_machine_extension" "bootstrap" {
  depends_on = [
    azurerm_virtual_machine_extension.aad,
    azurerm_virtual_machine_extension.monitoring,
    azurerm_virtual_machine_extension.da,
    azurerm_virtual_machine_extension.guesthealth,
    azurerm_virtual_machine_extension.azuremonitor,
    azurerm_virtual_machine_extension.guestattestation,
    azurerm_virtual_machine_extension.guestconfiguration,
    azurerm_virtual_machine_extension.networkwatcher
  ]
  count                      = var.avd_vm_count
  name                       = "custom-FileBootstrap"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  settings                   = <<SETTINGS
    {
        "commandToExecute": "powershell -ExecutionPolicy unrestricted -NoProfile -NonInteractive -command \"cp c:/azuredata/customdata.bin c:/azuredata/bootstrap.ps1; c:/azuredata/bootstrap.ps1; shutdown -r -t 10; exit 0;\""
    }
    SETTINGS
}

# Add the session host to the host pool.
# Note that 'aadJoin: true' just adds a hard 6 minute sleep in, and nothing else as far as I can tell.
# We do this after the join to ensure the host pool health doesn't complain about aad and may as well get extensions out of the way, too.
# Seems to be a few locations you can grab the DSC config from, and nowhere says definitively which is the appropriate place. E.g:
#  - https://raw.githubusercontent.com/Azure/RDS-Templates/master/ARM-wvd-templates/DSC/Configuration.zip
#  - https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration.zip
# The GitHub ones seem newer, so going with that.

resource "azurerm_virtual_machine_extension" "addsessionhost" {
  depends_on = [
    azurerm_virtual_machine_extension.bootstrap
  ]
  name                       = "ext-AddSessionHost"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.vm.*.id, count.index)
  publisher                  = "Microsoft.Powershell"
  count                      = var.avd_vm_count
  type                       = "DSC"
  type_handler_version       = "2.9"
  auto_upgrade_minor_version = true
  settings                   = <<SETTINGS
    {
        "ModulesUrl": "https://raw.githubusercontent.com/Azure/RDS-Templates/master/ARM-wvd-templates/DSC/Configuration.zip",
        "ConfigurationFunction" : "Configuration.ps1\\AddSessionHost",
        "Properties": {
            "hostPoolName": "${azurerm_virtual_desktop_host_pool.hostpool.name}",
            "registrationInfoToken": "${azurerm_virtual_desktop_host_pool_registration_info.token.token}",
            "aadJoin": true
        }
    }
SETTINGS
}

/*
Currently not supported via OIDC authentication. Drop to an alternate authentication method or run manually.
# https://github.com/hashicorp/terraform-provider-azuread/issues/803

# The AAD group we provide access to AVD through.
data "azuread_group" "aad_group" {
  display_name     = "Azure Virtual Desktop Standard Users"
  security_enabled = true
}

# The AAD group we provide administrative access to AVD through.
data "azuread_group" "aad_group_administrators" {
  display_name     = "Azure Virtual Desktop Local Administrators"
  security_enabled = true
}

# Apply the IAM configuration.
resource "azurerm_role_assignment" "vm_user_role" {
  scope                = data.azurerm_resource_group.rg.id
  role_definition_name = "Virtual Machine User Login"
  principal_id         = data.azuread_group.aad_group.id
}

resource "azurerm_role_assignment" "vm_administrator_role" {
  scope                = data.azurerm_resource_group.rg.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = data.azuread_group.aad_group_administrators.id
}

resource "azurerm_role_assignment" "desktop_role" {
  scope                = azurerm_virtual_desktop_application_group.dag.id
  role_definition_name = "Desktop Virtualization User"
  principal_id         = data.azuread_group.aad_group.id
}

resource "azurerm_role_assignment" "desktop_role_administrators" {
  scope                = azurerm_virtual_desktop_application_group.dag.id
  role_definition_name = "Desktop Virtualization User"
  principal_id         = data.azuread_group.aad_group_administrators.id
}
*/