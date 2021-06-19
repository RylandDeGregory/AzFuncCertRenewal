# Serverless Let's Encrypt certificate renewal on Azure

- Let's Encrypt ACME certificate renewal using [Azure Functions](https://docs.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell?tabs=portal) and PowerShell ([Posh-ACME](https://github.com/rmbolger/Posh-ACME)).
- Domain verification is performed automatically by Posh-ACME using its [Azure DNS plugin](https://github.com/rmbolger/Posh-ACME/blob/main/Posh-ACME/Plugins/Azure-Readme.md) and the Function App's [System-Assigned Managed Identity](https://docs.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=dotnet#add-a-system-assigned-identity).
- Updated certificate is automatically imported to [Azure Key Vault](https://docs.microsoft.com/en-us/azure/key-vault/certificates/certificate-scenarios) as a new version of the existing certificate.
    - Azure CDN custom domain is configured to point to the `latest` version of the certificate in Azure Key Vault, so it is automatically rotated when the certificate is renewed.
- Posh-ACME state is maintained by an [Azure Storage Account](https://docs.microsoft.com/en-us/azure/storage/common/storage-account-overview) [Blob container](https://docs.microsoft.com/en-us/azure/storage/blobs/storage-blobs-introduction) and [AzCopy](https://docs.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10).

## Getting Started

The following instructions assume that you are already hosting your website with [Azure CDN](https://docs.microsoft.com/en-us/azure/cdn/cdn-overview) and using [Azure DNS](https://docs.microsoft.com/en-us/azure/dns/dns-overview) with your domain.

### Setup

1. Create a Key Vault and Storage Account (if you don't already have one).
1. Install the [Posh-ACME PowerShell module](https://www.powershellgallery.com/packages/Posh-ACME/4.5.0) on your workstation.
1. Clone this git repository to your workstation.

### Generate a certificate locally

1. Configure your Posh-ACME environment by following the module's [tutorial](https://github.com/rmbolger/Posh-ACME/blob/main/Tutorial.md).
1. Generate a certificate locally by following the module's [Azure Readme](https://github.com/rmbolger/Posh-ACME/blob/main/Posh-ACME/Plugins/Azure-Readme.md).

### Add the certificate to Azure Key Vault

1. Import the newly-generated certificate's `fullchain.pfx` file to Azure Key Vault. You can get the password by executing the following command:

```powershell
(Get-PACertificate).pfxPass | ConvertFrom-SecureString -AsPlainText
```

<img width="718" alt="Add certificate to Azure Key Vault" src="https://user-images.githubusercontent.com/18073815/122643453-ef88c580-d0dd-11eb-887a-c8c1739ec890.png">


### Configure the CDN custom domain to use the Key Vault certificate

1. In your CDN endpoint's custom domain, select the Key Vault certificate you just imported (make sure the CDN can access the Key Vault).

<img width="706" alt="Configure CDN to use Key Vault certificate" src="https://user-images.githubusercontent.com/18073815/122644459-3fb65680-d0e3-11eb-834f-7fe8af65afbc.png">


### Deploy repo to a Function App

1. Deploy this repository to a Function App (I used [VS Code and its Azure Functions extension](https://docs.microsoft.com/en-us/azure/azure-functions/create-first-function-vs-code-powershell)).
1. Configure two [Application Settings](https://docs.microsoft.com/en-us/azure/azure-functions/functions-how-to-use-azure-function-app-settings?tabs=portal) in the Function App that specify the name of the Key Vault (`KEY_VAULT_NAME`) and the name of the certificate within the Key Vault (`AKV_CERT_NAME`).
1. Enable the Function App's System Managed Identity and grant it access to the Key Vault.

### Push local Posh-ACME state to Storage Account

1. Upload the contents of the `$env:POSHACME_HOME` directory to an empty **PRIVATE** blob container called `acme`.
1. Generate a container-level read/write [SAS URL](https://docs.microsoft.com/en-us/azure/storage/common/storage-sas-overview) for `acme` and [add it to the Key Vault as a secret](https://docs.microsoft.com/en-us/azure/key-vault/secrets/quick-create-portal) called `ACME-SAS`.
<img width="589" alt="acme container within Storage Account" src="https://user-images.githubusercontent.com/18073815/122643383-85702080-d0dd-11eb-80bb-456ed637b66e.png">
<img width="687" alt="acme container SAS URL within Key Vault" src="https://user-images.githubusercontent.com/18073815/122643578-89e90900-d0de-11eb-80b0-47aca61f549c.png">

### Run the Function App

1. The Function App's only Function, `RenewCert`, is configured with a [timer trigger](https://docs.microsoft.com/en-us/azure/azure-functions/functions-bindings-timer?tabs=powershell) that executes the Function once per week. You can also [execute the function at-will from the VS Code extension](https://docs.microsoft.com/en-us/azure/azure-functions/functions-develop-vs-code?tabs=csharp#run-functions-in-azure).
1. If everything is configured correctly, the Function will:
    1. Get the Storage Account SAS URL from Azure Key Vault.
    1. Check if AzCopy is installed in the Function App. If it isn't, install it.
    1. Use AzCopy to copy the Posh-ACME state from the `acme` Blob container to the Function App.
    1. Use Posh-ACME to check if the certificate needs to be renewed:
        * If it does:
            * Renew the certificate using Posh-ACME.
            * Add the updated certificate to Azure Key Vault (overwriting the expired certificate).
            * Push the updated Posh-ACME state from the Function App to the `acme` Blob container.
            * The CDN will automatically pull and deploy the `latest` version of the certificate.
        * If it does not, do nothing.

## Thanks

A lot of the Posh-ACME code (and the idea to store the Posh-ACME state in Azure Storage) was taken from [@brent-robinson](https://github.com/brent-robinson)'s fantastic [Medium article](https://medium.com/@brentrobinson5/automating-certificate-management-with-azure-and-lets-encrypt-fee6729e2b78) on setting this up using Azure DevOps Pipelines.
