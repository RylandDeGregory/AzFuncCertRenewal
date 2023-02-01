# Serverless Let's Encrypt certificate renewal on Azure

- Let's Encrypt ACME certificate renewal using [Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell?tabs=portal) and PowerShell ([Posh-ACME](https://github.com/rmbolger/Posh-ACME)).
- Domain verification is performed automatically by Posh-ACME using its [Azure DNS plugin](https://poshac.me/docs/v4/Plugins/Azure/) and the Function App's [System-Assigned Managed Identity](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=dotnet#add-a-system-assigned-identity).
- Updated certificate is automatically imported to [Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-scenarios) as a new version of the existing certificate.
    - Azure CDN custom domain is configured to point to the `latest` version of the certificate in Azure Key Vault, so it is automatically rotated when the certificate is renewed.
- Posh-ACME state is maintained by an [Azure Storage Account](https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview) [Blob container](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blobs-introduction) and [AzCopy](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10).

## Getting Started

The following instructions assume that you are using [Azure DNS](https://learn.microsoft.com/en-us/azure/dns/dns-overview) with your domain.

### Setup

1. Install the [Posh-ACME PowerShell module](https://www.powershellgallery.com/packages/Posh-ACME/4.5.0) on your workstation.
1. Clone this git repository to your workstation.

### Generate a certificate locally

1. Configure your Posh-ACME environment by following the module's [tutorial](https://poshac.me/docs/v4/Tutorial/).
1. Generate a certificate locally by following the module's [Azure Readme](https://poshac.me/docs/v4/Plugins/Azure/).

## Usage

### Infrastructure


### Function App

1. The Function App's only Function, `RenewCert`, is configured with a [timer trigger](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-timer?tabs=powershell) that executes the Function once per week. You can also [execute the function at-will from the VS Code extension](https://learn.microsoft.com/en-us/azure/azure-functions/functions-develop-vs-code?tabs=csharp#run-functions-in-azure).
1. If everything is configured correctly, the Function will:
    1. Get the Storage Account SAS URL from Azure Key Vault.
    1. Use AzCopy to copy the Posh-ACME state from the `acme` Blob container to the Function App.
    1. Use Posh-ACME to check if the certificate(s) need to be renewed:
        * If it does:
            * Renew the certificate(s) using Posh-ACME.
            * Add the updated certificate(s) to Azure Key Vault (overwriting the expired certificate(s)).
            * Push the updated Posh-ACME state from the Function App to the `acme` Blob container.
            * The CDN will automatically pull and deploy the `latest` version of the certificate(s).
        * If it does not, do nothing.

## Optional

### Configure Azure CDN custom domain to use Key Vault certificate

1. Navigate to your CDN profile, then to the endpoint using the Azure Portal.
2. Open the CDN endpoint's custom domain that you want to assign the certificate to.
3. In the custom domain, select the Key Vault certificate you just imported (make sure the Azure CDN identity can access the Key Vault).

<img width="706" alt="Configure Azure CDN to use Key Vault certificate" src="https://user-images.githubusercontent.com/18073815/122644459-3fb65680-d0e3-11eb-834f-7fe8af65afbc.png">
