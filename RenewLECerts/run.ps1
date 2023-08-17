#region Init
param($Timer)

# Session configuration
$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# Set variables from Function App Settings
$KeyVaultName       = $env:KEY_VAULT_NAME
$StorageAccountName = $env:STORAGE_ACCOUNT_NAME
$BlobContainerName  = $env:BLOB_CONTAINER_NAME

# Set Posh-ACME base directory
$TempDir = Join-Path $env:AzureWebJobsScriptRoot 'tmp'
$env:POSHACME_HOME = $TempDir

# Get Subscription ID from MSI context
$SubscriptionId = (Get-AzContext).Subscription.Id
#endregion Init

#region Functions
function Start-AzStorageBlobContainerSync {
    <#
        .SYNOPSIS
            Synchronize filesystem changes in a local directory to an Azure Storage blob container.
        .NOTES
            File changes are detected by differences in ContentMD5 value between a local file and the Azure blob with the same name.
    #>
    [CmdletBinding()]
    [OutputType([Int])]
    param (
        # Azure Storage Context
        [Parameter(Mandatory)]
        [Microsoft.WindowsAzure.Commands.Storage.AzureStorageContext] $Context,

        # Azure Storage Account Blob Container name
        [Parameter(Mandatory)]
        [String] $Container,

        # Local Filesystem Path to directory containing $Container folder
        [Parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [String] $LiteralPath
    )

    process {
        $Separator = [IO.Path]::DirectorySeparatorChar
        if ($LiteralPath -notmatch "$Separator$") {
            Write-Verbose "Append directory separator character [$Separator] to end of LiteralPath [$LiteralPath]"
            $LiteralPath += $Separator
        }

        $BlobHash = Get-AzStorageBlob -Context $Context -Container $Container | ForEach-Object {
            $_.ICloudBlob.FetchAttributes()
            [PSCustomObject]@{
                Name       = $_.Name
                ContentMD5 = $_.ICloudBlob.Properties.ContentMD5
                HexMD5     = [system.convert]::ToHexString([System.Convert]::FromBase64String($_.ICloudBlob.Properties.ContentMD5))
            }
        } | Sort-Object -Property Name
        Write-Verbose "Got MD5 Hash for [$($BlobHash.Count)] Azure Storage Blobs"

        $FileHash = Get-ChildItem -Path $LiteralPath -Recurse -File | ForEach-Object {
            $Hash = Get-FileHash -Path $_.FullName -Algorithm MD5 | Select-Object -ExpandProperty Hash
            [PSCustomObject]@{
                Name       = $_.FullName.Split($LiteralPath)[1]
                ContentMD5 = [system.convert]::ToBase64String([system.convert]::FromHexString($Hash))
                HexMD5     = $Hash
            }
        } | Sort-Object -Property Name
        Write-Verbose "Got MD5 hash for [$($FileHash.Count)] local files"

        $DiffFiles = Compare-Object -ReferenceObject $BlobHash -DifferenceObject $FileHash -Property Name, ContentMD5 | Where-Object { $_.SideIndicator -EQ '=>' }
        Write-Verbose "[$($DiffFiles.Count)] local files have been updated. Uploading to Azure Storage container [$Container]"

        $DiffFiles | ForEach-Object {
            $FileName = $_.Name
            $RelativeFilePath = $FileHash | Where-Object { $_.Name -eq $FileName } | Select-Object -ExpandProperty Name
            $FilePath = "$($LiteralPath)$RelativeFilePath"
            Write-Verbose "Upload file [$FilePath] to Azure Storage Blob Container [$Container] as [$FileName]"
            Set-AzStorageBlobContent -Context $Context -Container $Container -Blob $FileName -File $FilePath -Force
        }

        if ($DiffFiles.Count -gt 0) {
            return $DiffFiles.Count
        }
    }
}
#endregion Functions

#region Configure
# Create Azure Storage Context
$StorageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

Write-Information 'Generate ARM Access Token using Function App MSI'
$AzToken = (Get-AzAccessToken -ResourceTypeName ResourceManager).Token

# Remove local temp directory if it exists
if (Test-Path -Path $TempDir) {
    Remove-Item -Path $TempDir -Recurse -Force
}

Write-Information "Create Posh-ACME home directory [$TempDir]"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

Write-Information "Sync current Posh-ACME configuration from Storage Account [$StorageAccountName] to $TempDir"
Get-AzStorageBlob -Context $StorageCtx -Container $BlobContainerName | ForEach-Object {
    Get-AzStorageBlobContent -Context $StorageCtx -Container $BlobContainerName -Blob $_.Name -Destination $TempDir
}

Write-Information "Initialize Posh-ACME in $TempDir"
Import-Module Posh-ACME -Force -Verbose

try {
    Write-Information 'Get certificate orders from synced Posh-ACME directory'
    $CertOrders = Get-PAOrder -List
} catch {
    Write-Error 'Posh-ACME cannot detect certificate order. Please ensure that $env:POSHACME_HOME is properly configured, and the certificate order is in that location'
}

try {
    Write-Information 'Get certificates from Azure Key Vault'
    $AKVCerts = Get-AzKeyVaultCertificate -VaultName $KeyVaultName | ForEach-Object { Get-AzKeyVaultCertificate -VaultName $_.VaultName -Name $_.Name }
} catch {
    Write-Error "Error getting certificates from Azure Key Vault [$KeyVaultName]: $_"
}
#endregion Configure

#region Process
foreach ($CertOrder in $CertOrders) {
    Write-Information "Get LetsEncrypt certificate order for [$($CertOrder.MainDomain)] from Posh-ACME config"

    # Set certificate file information for Key Vault import
    $ServerName  = ([uri](Get-PAServer).location).host
    $AccountName = (Get-PAAccount).id
    $CertFile    = [IO.Path]::Combine($TempDir, $ServerName, $AccountName, $CertOrder.MainDomain, 'fullchain.pfx')

    # Select AKV certificate based on the domain name associated with the current LetsEncrypt certificate
    $AKVCertName = $CertOrder.MainDomain.Replace('.','-')
    $AKVCert = $AKVCerts | Where-Object { $_.Certificate.Subject.Replace('CN=','') -eq $CertOrder.MainDomain }

    if (-not $AKVCert) {
        Write-Information "No Azure Key Vault certificate exists for [$($CertOrder.MainDomain)]. Importing certificate from Posh-ACME configuration"
        $AKVCert = Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -FilePath $CertFile -Password $(ConvertTo-SecureString -String $CertOrder.PfxPass -AsPlainText -Force)
    }

    # Get LetsEncrypt certificate object
    $LECert = Get-PACertificate -MainDomain $CertOrder.MainDomain

    # Check if the LetsEncrypt certificate is available for renewal
    if ($CertOrder.RenewAfter -and ((Get-Date $CertOrder.RenewAfter) -le (Get-Date))) {
        Write-Information "Certificate is ready for renewal as of [$(Get-Date $CertOrder.RenewAfter)]. Renewing certificate..."

        # Ensure that the AKV certificate matches the LetsEncrypt certificate synced from Azure Storage
        if ($AKVCert.Thumbprint -eq $LECert.Thumbprint) {
            Write-Information "Certificate is [$($CertOrder.status)]. Submitting renewal for certificate with thumbprint [$($LECert.Thumbprint)]"

            # Renew the certificate using Posh-ACME and the Azure DNS plugin
            $NewCert = Submit-Renewal -PluginArgs @{ AZSubscriptionId = $SubscriptionId; AzAccessToken = $AzToken } -MainDomain $CertOrder.MainDomain -Verbose
        } elseif (-not $AKVCert) {
            Write-Error "Azure Key Vault certificate with name [$AKVCertName] was not found in Key Vault [$KeyVaultName]"
        } else {
            Write-Error "Azure Key Vault certificate thumbprint [$($AKVCert.Thumbprint)] does not match LetsEncrypt certificate thumbprint [$($LECert.Thumbprint)] prior to renewal. Please eliminate the inconsistency"
        }

        # Ensure that a new certificate was generated by Posh-ACME and that it does not match the current AKV certificate
        if ($NewCert -and $AKVCert.Thumbprint -ne $NewCert.Thumbprint) {
            if (Test-Path $CertFile) {
                Write-Information "Import updated certificate [$CertFile] with thumbprint [$($NewCert.Thumbprint)] to Azure Key Vault"
                Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -FilePath $CertFile -Password $NewCert.PfxPass

                Write-Information 'Sync updated Posh-ACME configuration to Storage Account'
                Start-AzStorageBlobContainerSync -Context $StorageCtx -Container $BlobContainerName -LiteralPath $TempDir -Verbose
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

        Write-Information "Import certificate with thumbprint [$($LECert.Thumbprint)] to Azure Key Vault"
        Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $AKVCertName -FilePath $CertFile -Password $LECert.PfxPass
    } elseif (-not $CertOrder.RenewAfter) {
        Write-Error "Certificate for $($CertOrder.MainDomain) does not have a 'RenewAfter' value. Please confirm that the Storage Account and Function App state are in sync"
    } else {
        Write-Information "Certificate is valid until $(Get-Date $CertOrder.CertExpires). No action required for this certificate"
    }
}

Write-Information "Remove Posh-ACME configuration files from local directory [$TempDir]"
Remove-Item -Path $TempDir -Recurse -Force

Write-Information 'Complete.'
#endregion Process