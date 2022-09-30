#region Init
param($Timer)

# Disable progress messages
$global:ProgressPreference = 'SilentlyContinue'

# Stop on error
$ErrorActionPreference = 'Stop'

# Get variables from Function App Settings
$KeyVaultName = $env:KEY_VAULT_NAME
$AKVCertNames = $env:AKV_CERT_NAME -split ', '
$TempDir      = $env:POSHACME_HOME

# Get Subscription Id and Tenant Id from the Function context
$SubscriptionId = (Get-AzContext).Subscription.Id
$TenantId       = (Get-AzContext).Tenant.Id
#endregion Init

#region Configure
# Get Storage Account secret from Key Vault
Write-Information 'Getting Storage Account connection information'
$SasUrl = Get-AzKeyVaultSecret -VaultName $KeyVaultName -SecretName 'ACME-SAS' -AsPlainText

# Generate an Azure Access Token for use by Posh-ACME with the Azure DNS plugin
Write-Information 'Generating Access Token using Function App MSI'
$AzToken = (Get-AzAccessToken -ResourceUrl 'https://management.core.windows.net/' -TenantId $TenantId).Token

# Create Posh-ACME config directory if it does not exist
if (-not (Test-Path -Path $TempDir)) {
    Write-Information 'Creating Posh-ACME home directory'
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

# Download Posh-ACME configuration from Azure Storage using AzCopy
Write-Information "Syncing current Posh-ACME configuration from Storage Account to $TempDir"
.\azcopy.exe sync $SasUrl $TempDir --delete-destination true

# Initialize Posh-ACME
Write-Information "Initializing Posh-ACME in $TempDir"
Import-Module Posh-ACME -Force -Verbose

try {
    # Get LetsEncrypt certificate order configuration
    Write-Information 'Getting certificate orders from synced Posh-ACME directory'
    $CertOrders = Get-PAOrder -List
} catch {
    Write-Error 'Posh-ACME cannot detect certificate order. Please ensure that $env:POSHACME_HOME is properly configured, and the certificate order is in that location'
}
#endregion Configure

#region Renew
foreach ($CertOrder in $CertOrders) {
    Write-Information "Found LetsEncrypt certificate configuration for $($CertOrder.MainDomain)"

    # Select AKV certificate name based on the domain name associated with the current LetsEncrypt certificate
    if ($CertOrder.MainDomain -like 'www*') {
        $AKVCertName = $AKVCertNames | Where-Object { $_ -like 'www*' }
    } else {
        $AKVCertName = $AKVCertNames | Where-Object { $_ -notlike 'www*' }
    }

    # Get Azure Key Vault certificate object
    $AKVCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName

    # Get LetsEncrypt certificate object
    $LECert = Get-PACertificate -MainDomain $CertOrder.MainDomain

    # Check if the LetsEncrypt certificate is available for renewal
    if ($CertOrder.RenewAfter -and ((Get-Date $CertOrder.RenewAfter) -le (Get-Date))) {
        Write-Information "Certificate is ready for renewal as of $(Get-Date $CertOrder.RenewAfter). Renewing certificate..."

        # Ensure that the AKV certificate matches the LetsEncrypt certificate synced from Azure Storage
        if ($AKVCert.Thumbprint -eq $LECert.Thumbprint) {
            Write-Information "Certificate is $($CertOrder.status). Submitting renewal for certificate with thumbprint: $($LECert.Thumbprint)"

            # Renew the certificate using Posh-ACME and the Azure DNS plugin
            $NewCert = Submit-Renewal -PluginArgs @{ AZSubscriptionId = $SubscriptionId; AzAccessToken = $AzToken } -MainDomain $CertOrder.MainDomain -Verbose
        } elseif (-not $AKVCert) {
            Write-Error "Azure Key Vault certificate with name $AKVCertName was not found in Key Vault $KeyVaultName"
        } else {
            Write-Error "Azure Key Vault certificate thumbprint [$($AKVCert.Thumbprint)] does not match LetsEncrypt certificate thumbprint [$($LECert.Thumbprint)] prior to renewal. Please eliminate the inconsistency"
        }

        # Ensure that a new certificate was generated by Posh-ACME and that it does not match the current AKV certificate
        if ($NewCert -and $AKVCert.Thumbprint -ne $NewCert.Thumbprint) {
            # Set certificate file information for Key Vault import
            $ServerName  = ([system.uri](Get-PAServer).location).host
            $AccountName = (Get-PAAccount).id
            $CertFile    = [IO.Path]::Combine($TempDir, $ServerName, $AccountName, $CertOrder.MainDomain, 'fullchain.pfx')

            if (Test-Path $CertFile) {
                # Add the updated certificate to Azure Key Vault
                Write-Information "Importing updated certificate [$CertFile] with thumbprint [$($NewCert.Thumbprint)] to Azure Key Vault"
                Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -FilePath $CertFile -Password $NewCert.PfxPass

                # Upload updated certificate configuration to Azure Storage
                Write-Information 'Syncing updated Posh-ACME configuration to Storage Account'
                .\azcopy.exe sync $TempDir $SasUrl
                Write-Information 'Sync to Storage Account successful. Renewal complete.'
            } else {
                Write-Error "Certificate [$CertFile] is not valid for import to Azure Key Vault"
            }
        } elseif (-not $NewCert) {
            Write-Error 'Certificate was not successfully renewed by Posh-ACME'
        }
    } elseif ($AKVCert.Thumbprint -ne $LECert.Thumbprint) {
        # Set certificate file information for Key Vault import
        $ServerName  = ([system.uri](Get-PAServer).location).host
        $AccountName = (Get-PAAccount).id
        $CertFile    = [IO.Path]::Combine($TempDir, $ServerName, $AccountName, $CertOrder.MainDomain, 'fullchain.pfx')

        # Add the updated certificate to Azure Key Vault
        Write-Information "Importing certificate with thumbprint [$($LECert.Thumbprint)] to Azure Key Vault"
        Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -FilePath $CertFile -Password $LECert.PfxPass
    } elseif (-not $CertOrder.RenewAfter) {
        Write-Error "Certificate for $($CertOrder.MainDomain) does not have a 'RenewAfter' value. Please confirm that the Storage Account and Function App state are in sync"
    } else {
        Write-Information "Certificate is valid until $(Get-Date $CertOrder.CertExpires). No action required for this certificate"
    }
}
Write-Information "Complete."
#endregion Renew
