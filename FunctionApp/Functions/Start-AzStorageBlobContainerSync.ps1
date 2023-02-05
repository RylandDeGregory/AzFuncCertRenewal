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

        $BlobHash = Get-AzStorageBlob -Context $Context -Container $Container - | ForEach-Object {
            $_.ICloudBlob.FetchAttributes()
            [PSCustomObject]@{
                Name       = $_.Name
                ContentMD5 = $_.ICloudBlob.Properties.ContentMD5
                HexMD5     = [system.convert]::ToHexString([System.Convert]::FromBase64String($_.ICloudBlob.Properties.ContentMD5))
            }
        } | Sort-Object -Property Name
        Write-Verbose "Got MD5 Hash for [$($BlobHash.Count)] Azure Storage Blobs"

        $FilePath = Join-Path $LiteralPath $Container
        $FileHash = Get-ChildItem -Path $FilePath -Recurse -File | ForEach-Object {
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
            Set-AzStorageBlobContent -Context $Context -Container $Container -Blob $FileName -File $FilePath -Force -WhatIf
        }

        if ($DiffFiles.Count -gt 0) {
            return $DiffFiles.Count
        }
    }
}