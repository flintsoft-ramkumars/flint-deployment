function Download-GHCRImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName,

        [Parameter(Mandatory = $false)]
        [string]$Tag = "latest"
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $CleanFolderName = "$($ImageName.Replace('/', '_'))-$Tag"
    $OutputPath = Join-Path $PWD $CleanFolderName

    if (!(Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    }

    Write-Host "Connecting to GitHub Container Registry for: ghcr.io/$ImageName:$Tag" -ForegroundColor Cyan

    $TokenUri = "https://ghcr.io"
    try {
        $TokenResponse = Invoke-RestMethod -Uri $TokenUri -Method Get
        $Token = $TokenResponse.token
    } catch {
        Write-Error "Failed to fetch authentication token from GHCR. Verify if image name is spelled right."
        return
    }

    $Headers = @{
        "Authorization" = "Bearer $Token"
        "Accept"        = "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
    }

    $ManifestUri = "https://ghcr.io"
    Write-Host "Retrieving manifest..." -ForegroundColor Yellow
    try {
        $Manifest = Invoke-RestMethod -Uri $ManifestUri -Headers $Headers -Method Get
    } catch {
        Write-Error "Failed to retrieve manifest. The tag might not exist."
        return
    }

    $ConfigDigest = $Manifest.config.digest
    if ($ConfigDigest) {
        Write-Host "Downloading image configuration JSON..." -ForegroundColor Gray
        $ConfigUri = "https://ghcr.io"
        Invoke-RestMethod -Uri $ConfigUri -Headers $Headers -OutFile (Join-Path $OutputPath "config.json")
    }

    $Layers = $Manifest.layers
    if (!$Layers) {
        Write-Error "No download layers found in manifest."
        return
    }

    Write-Host "Found $($Layers.Count) image layers. Starting downloads..." -ForegroundColor Green

    $ManifestLayersJson = @()
    $TempBlobFile = Join-Path $OutputPath "blobtmp"

    foreach ($Layer in $Layers) {
        $Digest = $Layer.digest
        
        # FIXED: Removed the inline string interpolation to stop the parser error
        $RawHash = $Digest.Replace('sha256:', '')
        $CleanFileName = $RawHash + ".tar.gz"
        
        $TargetFile = Join-Path $OutputPath $CleanFileName
        $ManifestLayersJson += $CleanFileName

        Write-Host "Downloading layer: $CleanFileName" -ForegroundColor Gray

        $BlobUri = "https://ghcr.io"
        Invoke-RestMethod -Uri $BlobUri -Headers $Headers -OutFile $TempBlobFile
        Move-Item -Path $TempBlobFile -Destination $TargetFile -Force
    }

    $LocalManifest = @{
        Config   = "config.json"
        RepoTags = @("ghcr.io/$ImageName:$Tag")
        Layers   = $ManifestLayersJson
    }

    $LocalManifest | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputPath "manifest.json") -Encoding ascii

    Write-Host "`nSuccess! Downloader completed." -ForegroundColor Green
    Write-Host "Files saved to: $OutputPath" -ForegroundColor Cyan
    Write-Host "To bundle this into a portable tar archive, run:" -ForegroundColor Yellow
    Write-Host "tar -cvf $CleanFolderName.tar -C $OutputPath ." -ForegroundColor White
}
