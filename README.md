# Serverless Let's Encrypt certificate renewal on Azure

- Let's Encrypt ACME certificate renewal using Azure Functions and PowerShell ([Posh-ACME](https://github.com/rmbolger/Posh-ACME)).
- Domain verification is performed automatically by Posh-ACME using its [Azure DNS plugin](https://github.com/rmbolger/Posh-ACME/blob/main/Posh-ACME/Plugins/Azure-Readme.md) and the Function App's [System-Assigned Managed Identity](https://docs.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=dotnet#add-a-system-assigned-identity).
- Updated certificate is automatically imported to Azure Key Vault as a new version of the existing certificate.
    - Azure CDN is configured with a custom domain certificate pointing to the `latest` version in Azure Key Vault, so it is automatically rotated when the certificate is renewed.
- Posh-ACME state is maintained by an Azure Blob Storage Account and AzCopy.

### Thanks

A lot of the Posh-ACME code (and the idea to store Posh-ACME state in Azure Storage) was taken from Brent Robinson's [fantastic Medium article](https://medium.com/@brentrobinson5/automating-certificate-management-with-azure-and-lets-encrypt-fee6729e2b78) on setting this up using Azure DevOps Pipelines.