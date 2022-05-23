# Cloud-Native Azure Virtual Desktop 

This workflow provisions an Azure Virtual Desktop into an Azure subscription using GitHub Actions and Terraform. The virtual desktop is integrated into Intune, fully managed, and supports Azure AD-only accounts for authentication. No hybrid identity or hybrid management is required to support the desktop, nor is Azure Active Directory Domain Services, and the provisioning is password-less via OIDC.

Due to cloud-native approach, the current limitations in Azure Files – specifically the fact that the new Kerberos ticketing support in Azure AD support [still requires a hybrid identity as a pre-requisite](https://docs.microsoft.com/en-us/azure/virtual-desktop/create-profile-container-azure-ad#prerequisites) – means that good old fashioned local profiles are used instead of FSLogix. It would likely be trivial to adopt an FSLogix architecture if a hybrid identity was available to you.

## Authentication

We don't want to store secrets. 

Instead, we're going to leverage the [OIDC-based authentication process](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure) for GitHub Actions and Azure. This process, once established, means we don't need to store any secrets inside of GitHub for the actions workflow to provision things inside of our Azure subscription. Terraform (as of v1.2) and the AzureRM provider (as of v3.7) fully supports this approach, which means our declarative provisioning process is fully password-less! 

## Boostrappping

We need to bootstrap both GitHub (our repository and workflow) and Azure (where we will deploy stuff) to facilitate our automated deployments. In the spirit of our secret-less deploy, we're going to perform the initial local bootstrapping interactively in memory with a short-lived GitHub access token and our existing Azure privileges. 

This allows us to provision the application and resource group Azure, and then communicate with the GitHub API to write the strings back as GitHub secrets. These are then used as part of the actions workflow authentication, and future pipeline execution processes. It's important to note that these are not secret, but we are simply storing them as secrets as a best practice.

## State

We need to store Terraform state. The state ensures we can track state of our infrastructure across our workflows and leverage Terraform to manage it. To support our workflows and deploy from anywhere, we need to persist the state so we can continue to refer to it as the source of truth. As part of the bootstrapping process, we will establish a container within our resource group to hold the state for the virtual desktop and associated services. We can then pass these details on to Terraform as part of our initialisation process. We will keep the bootstrapping state local, as it's a once off task - although you could absolutely use the same approach for it too.

## Install the Azure and Terraform CLIs

If they are not installed already, pick your favourite method:

- [Install the Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Install v1.2 or later of the Terraform CLI](https://learn.hashicorp.com/tutorials/terraform/install-cli)

## Generate your GitHub token

Create your own temporary [personal access token in GitHub](https://github.com/settings/tokens/new) using `repo` (all) and `read:org` (under `admin:org`) as the scopes.

## Write our variables

We're going to write out configuration as local environment variables the Terraform CLI can access. These are:

- Your generated GitHub PAT
- The Azure subscription ID to deploy into
- The Azure AD directory/tenant ID associated with that subscription
- The owner of the GitHub repository; and
- The name of the GitHub repository

```powershell
$env:TF_VAR_github_pat      = '<your-pat>'
$env:TF_VAR_tenant_id       = '<your-tenant-id>'
$env:TF_VAR_subscription_id = '<your-subscription-id>'
$env:TF_VAR_repo_owner      = '<your-repo-owner>'
$env:TF_VAR_repo_name       = '<your-repo-name>'
```

Log into Azure for our temporary Terraform authentication.

```powershell
az login
```

You may optionally want to set your subscription for testing purposes.

```powershell
az account set --subscription $env:TF_VAR_subscription_id
```

Initalise terraform and deploy our resources. Will prompt you for confirmation for the application of the configuration.

```powershell
cd terraform\bootstrap
terraform init
terraform apply
```

That's it! We've created the resource group, application, service principal and the associated federation configuration to support our OIDC-based authentication. This means we now have our bootstrapped Azure and GitHub environment, with our [secrets configured to boot](../../settings/secrets/actions).

## Run the workflow

To see the federated authentication in action, head over to [the actions workflow](../../actions/workflows/main.yml) defined through [main.yaml](.github/workflows/main.yml). 

We've configured the workflow_dispatch behaviour in our workflow definition to allow for the manual execution of the pipeline, just run it!

## Testing locally

Because we're using [a partial configuration](https://www.terraform.io/language/settings/backends/configuration#partial-configuration) for the backend remote state, and want to use non-persistent pipelines to manage our environment, you'll need to pass the additional key-value pairs during the `terraform init` process to consume this remote state. We do this automatically via the Actions configuration by consuming the secrets, so locally you will need to do the same. There are plenty of options here, such as using environment variables.

```powershell
cd \terraform\avd
terraform init -backend-config="resource_group_name=<your-resource-group-name>"
               -backend-config="storage_account_name=<your-storage-account-name>" \
               -backend-config="container_name=terraform-state" \
               -backend-config="key=terraform.avd.tfstate"
```

Alternatively, you can just drop the `backend` block entirely in [terraform/avd/main.tf](terraform/avd/main.tf), pass no additional arguments, and just store the state locally. This can be easier when making significant modifications and you want to quickly interrogate the state file.
## Notes

### Local development

When developing the terraform configuration, you may want to run the `terraform format`, `terraform validate` and `terraform plan` commands as part of your process. 

If modifying providers, be sure to run `terraform providers lock -platform=windows_amd64 -platform=linux_amd64` to ensure the workflow continues to run. You will need to run `terraform init -upgrade` first, if upgrading previously locked providers, once they are defined in your configuration.

### Update management

There's currently no way to configure update management natively. This looks to be coming in [the 4.0 release of the AzureRM provider](https://github.com/hashicorp/terraform-provider-azurerm/issues/2812). You could bake in an ARM template via `azurerm_template_deployment` if you wished. For now, a manual click on the VM and creation of an update deployment schedule will suffice. 

### Disk encryption

We're leveraging [encryption at host](https://docs.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview) as it provides the most flexibility, supports our use case, and requires a single line of HCL to activate. However, you may need to configure your subscription to support this feature if it has not been done before:

```powershell
# Register
az feature register --namespace "Microsoft.Compute" --name "EncryptionAtHost"

# Verify the state of the registration
az feature list -o table --query "[?contains(name, 'Microsoft.Compute/EncryptionAtHost')].{Name:name,State:properties.state}"

# Once complete, refresh the provider
az provider register --namespace Microsoft.Compute
```