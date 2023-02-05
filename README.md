# Serverless Let's Encrypt certificate renewal on Azure

- Let's Encrypt ACME certificate renewal using [Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell?tabs=portal) and PowerShell ([Posh-ACME](https://github.com/rmbolger/Posh-ACME)).
- Domain verification is performed automatically by Posh-ACME using its [Azure DNS plugin](https://poshac.me/docs/v4/Plugins/Azure/) and the Function App's [System-Assigned Managed Identity](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=dotnet#add-a-system-assigned-identity).
- Upon renewal, updated certificate is automatically imported to [Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-scenarios) as a new version of the existing certificate.
- Posh-ACME state is maintained in an [Azure Storage Account](https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview) [Blob container](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blobs-introduction), and kept in sync with the Function App using Azure PowerShell.

## Setup

The following instructions assume that you are using [Azure DNS](https://learn.microsoft.com/en-us/azure/dns/dns-overview) with your domain. If you are not, follow the Microsoft documentation to set up an Azure DNS Zone for your domain. [Tutorial: Host your domain in Azure DNS](https://learn.microsoft.com/en-us/azure/dns/dns-delegate-domain-azure-dns).

### Installation

1. Install the [Posh-ACME PowerShell module](https://www.powershellgallery.com/packages/Posh-ACME/4.5.0) on your workstation.
1. Clone this git repository to your workstation.
1. Deploy required Azure resources using the steps in the [Infrastructure](#infrastructure) section of this document.

### Generate a certificate locally

1. Configure your Posh-ACME environment by following the module's [tutorial](https://poshac.me/docs/v4/Tutorial/).
1. Generate a certificate locally by following the module's [Azure tutorial](https://poshac.me/docs/v4/Plugins/Azure/).

## Usage

### Infrastructure

This application can be deployed to Azure by clicking the Deploy to Azure button below. **NOTE:** Your Azure DNS Zone must be in a Resource Group in the same Subscription as the Resource Group you are deploying to.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FRylandDeGregory%2FAzFuncCertRenewal%2Fmain%2FInfrastructure%2Fmain.json)

This application can also be deployed to Azure programmatically using [Azure PowerShell](https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azresourcegroupdeployment) or the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/group/deployment?view=azure-cli-latest#az-group-deployment-create).

```PowerShell
# Azure PowerShell
New-AzResourceGroupDeployment -ResourceGroupName 'testing' -TemplateFile ./Infrastructure/main.bicep -dnsZoneName 'my-domain.com' -Verbose

# Azure CLI
az group deployment create --resource-group 'testing' --template-file ./Infrastructure/main.bicep --parameters "{ \"dnsZoneName\": { \"value\": \"my-domain.com\" } }" --verbose
```

### Add Posh-ACME config to Storage Account

Using the [Azure Storage Explorer](https://learn.microsoft.com/en-us/azure/vs-azure-tools-storage-manage-with-storage-explorer), upload the content of your local `$env:POSHACME_HOME` directory to the `acme` container within the Storage Account that was created as part of the [Infrastructure](#infrastructure) deployment.

<img width="656" alt="Storage Explorer" src="https://user-images.githubusercontent.com/18073815/216796822-cb05a5b2-701b-4544-9b50-a2f4a76a1980.png">

### Function App

1. The Function App's only Function, `RenewLECerts`, is configured with a [timer trigger](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-timer?tabs=powershell) that executes the Function once per week. You can also [execute the function at-will from the VS Code extension](https://learn.microsoft.com/en-us/azure/azure-functions/functions-develop-vs-code?tabs=csharp#run-functions-in-azure).
1. If everything is configured correctly, the Function will:
    1. Create a Storage Account Context using the Function App's MSI.
    1. Use Azure PowerShell to copy the Posh-ACME state from a Blob Container to the Function App.
    1. Use Posh-ACME to check if the certificate(s) need to be renewed:
        * If it/they does:
            * Renew the certificate(s) using Posh-ACME.
            * Add the updated certificate(s) to Azure Key Vault (overwriting the expired certificate(s)).
            * Push the updated Posh-ACME state from the Function App to the Blob Container, ensuring only modified files are updated.
        * If it/they do(es) not, do nothing.

## Optional

### Configure Azure CDN custom domain to use Key Vault certificate

1. Navigate to your CDN profile, then to the endpoint using the Azure Portal.

<img width="593" alt="Screenshot 2023-02-01 at 12 22 40 PM" src="https://user-images.githubusercontent.com/18073815/216117168-6b508aa8-47de-400a-b48c-041e1b19f337.png">

1. Open the CDN endpoint's custom domain that you want to assign the certificate to.
1. In the custom domain, select the Key Vault certificate you just imported (make sure the Azure CDN identity can access the Key Vault).

<img width="712" alt="Screenshot 2023-02-01 at 12 20 08 PM" src="https://user-images.githubusercontent.com/18073815/216116513-b8ec396f-7fec-4bcb-86aa-ddf277aadd3d.png">
