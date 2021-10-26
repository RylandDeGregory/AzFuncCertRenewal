#region Init
param($Timer)

# Disable progress messages from Posh-ACME module
$global:ProgressPreference = 'SilentlyContinue'

# Stop on error
$ErrorActionPreference = 'Stop'

# Get variables from Function App Settings
$KeyVaultName = $env:KEY_VAULT_NAME
$AKVCertName  = $env:AKV_CERT_NAME
#endregion Init

#region Configure
# Get Storage Account secret from Key Vault and Subscription Id from the Function context
Write-Host 'Getting Storage Account connection information'
$SasUrl = Get-AzKeyVaultSecret -VaultName $KeyVaultName -SecretName 'ACME-SAS' -AsPlainText
$SubscriptionId = (Get-AzContext).Subscription.Id

# Create Posh-ACME config directory
Write-Host 'Creating Posh-ACME config home'
$TempDir = './tmp'
if (Test-Path -Path $TempDir) {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# Download Posh-ACME configuration from Storage Account using AzCopy
Write-Host 'Syncing current Posh-ACME configuration from Storage Account'
.\azcopy.exe sync $SasUrl $TempDir --recursive

# Initialize Posh-ACME
Write-Host "Initializing PoshACME in $TempDir"
$env:POSHACME_HOME = $TempDir
Import-Module Posh-ACME -Force

try {
    # Get certificate order configuration
    $CertOrder = Get-PAOrder
} catch {
    Write-Error 'Posh-ACME cannot detect certificate order. Please ensure that $env:POSHACME_HOME is properly configured, and the certificate order is in that location.'
}

Write-Host "Got Posh-ACME certificate configuration for $($CertOrder.MainDomain)"
#endregion Configure

#region Renew
if ([datetime]$CertOrder.RenewAfter -le (Get-Date)) {
    # Get Azure Key Vault certificate file
    Write-Host "Certificate is ready for renewal as of $([datetime]$CertOrder.RenewAfter). Renewing certificate..."
    $AKVCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -ErrorAction SilentlyContinue

    if ($AKVCert -and $AKVCert.Thumbprint -eq (Get-PACertificate).Thumbprint) {
        Write-Host "Certificate is $($CertOrder.status). Submitting renewal for $($CertOrder.MainDomain) certificate with thumbprint: $CertThumbprint"
        $NewCert = Submit-Renewal -PluginArgs @{ AZSubscriptionId = $SubscriptionId; AZUseIMDS = $true }
    } else {
        Write-Error 'Azure Key Vault certificate thumbprint does not match Posh-ACME certificate thumbprint. Investigate and eliminate the inconsistency.'
    }

    if (-not $AKVCert -or $AKVCert.Thumbprint -ne $NewCert.Thumbprint) {
        # Set certificate file information for Key Vault import
        $ServerName  = ([system.uri](Get-PAServer).location).host
        $AccountName = (Get-PAAccount).id
        $CertFile    = [IO.Path]::Combine($TempDir, $ServerName, $AccountName, $CertOrder.MainDomain, 'fullchain.pfx')

        Write-Host "Importing updated certificate to Azure Key Vault with thumbprint: $($NewCert.Thumbprint)"
        Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -FilePath $CertFile -Password $NewCert.PfxPass

        Write-Host 'Syncing updated Posh-ACME configuration to Storage Account.'
        ./AzCopy.exe sync $TempDir $SasUrl --recursive
        Write-Host 'Sync to Storage Account successful. Complete.'
    } else {
        Write-Host 'Azure Key Vault certificate thumbprint matches Posh-ACME certificate thumbprint. Complete.'
    }
} else {
    Write-Host "Certificate for $($CertOrder.MainDomain) is valid until $($CertOrder.CertExpires). Complete."
}
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
#endregion Renew