<#
.SYNOPSIS
    Downloads container images from ghcr.io using only PowerShell. Docker is not required.

.DESCRIPTION
    Each image is saved as a .tar file in OCI layout format. The archive also contains
    a manifest.json, so "docker load" and "podman load" can import it on another machine.
    Works on Windows PowerShell 5.1 and PowerShell 7. Creating the .tar requires tar.exe,
    which is included with Windows 10 (1803) and later.

.EXAMPLE
    .\Get-GhcrImages.ps1 -Images "owner/app:latest", "ghcr.io/owner/tool:1.2.3"

.EXAMPLE
    # Private images: set a GitHub token with the read:packages scope first
    $env:GHCR_TOKEN = "<your token>"
    .\Get-GhcrImages.ps1 -Images "owner/private-app:latest" -Username "your-github-user"

.EXAMPLE
    # Choose a platform and output folder
    .\Get-GhcrImages.ps1 -Images "owner/app:latest" -Platform "linux/arm64" -OutputDir "D:\images"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Images,

    # Only needed for private images. The token is read from $env:GHCR_TOKEN.
    [string]$Username,

    # Used when an image is published for several platforms: os/arch or os/arch/variant.
    [string]$Platform = "linux/amd64",

    [string]$OutputDir = ".\images"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # The progress bar badly slows downloads in PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$registry = "ghcr.io"
$manifestTypes = @(
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json"
) -join ","

function Get-AuthHeader([string]$Repository) {
    $url = "https://$registry/token?service=$registry&scope=repository:${Repository}:pull"
    $headers = @{}

    if ($Username) {
        if (-not $env:GHCR_TOKEN) {
            throw "Set `$env:GHCR_TOKEN to a GitHub token with the read:packages scope."
        }
        $pair = [Text.Encoding]::UTF8.GetBytes("${Username}:$env:GHCR_TOKEN")
        $headers.Authorization = "Basic " + [Convert]::ToBase64String($pair)
    }

    $response = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing
    return @{ Authorization = "Bearer $($response.token)" }
}

function Save-VerifiedBlob {
    # Downloads a URL into the blob folder, named after the SHA-256 of its contents.
    param([string]$Repository, [string]$Url, [string]$Accept, [string]$ExpectedDigest, [string]$BlobDir)

    if ($ExpectedDigest) {
        $existing = Join-Path $BlobDir ($ExpectedDigest -replace '^sha256:', '')
        if (Test-Path -LiteralPath $existing) { return $ExpectedDigest }
    }

    # A fresh token per download stops long pulls failing when a token expires.
    $headers = Get-AuthHeader $Repository
    if ($Accept) { $headers.Accept = $Accept }

    $tempFile = Join-Path $BlobDir ([IO.Path]::GetRandomFileName())
    try {
        Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $tempFile -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $digest = "sha256:$hash"

        if ($ExpectedDigest -and $digest -ne $ExpectedDigest) {
            throw "Digest mismatch: expected $ExpectedDigest, got $digest"
        }

        $destination = Join-Path $BlobDir $hash
        Move-Item -LiteralPath $tempFile -Destination $destination -Force
        return $digest
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
}

function Save-Manifest([string]$Repository, [string]$Reference, [string]$BlobDir) {
    $expected = if ($Reference -like "sha256:*") { $Reference } else { $null }
    $url = "https://$registry/v2/$Repository/manifests/$Reference"
    return Save-VerifiedBlob -Repository $Repository -Url $url -Accept $manifestTypes `
        -ExpectedDigest $expected -BlobDir $BlobDir
}

function Read-Blob([string]$Digest, [string]$BlobDir) {
    $path = Join-Path $BlobDir ($Digest -replace '^sha256:', '')
    return [IO.File]::ReadAllText($path) | ConvertFrom-Json
}

function Write-TextFile([string]$Path, [string]$Text) {
    # Written without a byte order mark, which container tools can reject.
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-Image([string]$Image) {
    # Parse [ghcr.io/]owner/name[:tag][@sha256:digest]
    $name = $Image -replace "^$([regex]::Escape($registry))/", ''
    $reference = "latest"

    if ($name -match '^(?<repo>[^@]+)@(?<digest>sha256:[0-9a-f]{64})$') {
        $name = $Matches.repo -replace ':[^/]+$', ''
        $reference = $Matches.digest
    }
    elseif ($name -match '^(?<repo>.+):(?<tag>[^/:]+)$') {
        $name = $Matches.repo
        $reference = $Matches.tag
    }
    $name = $name.ToLowerInvariant()

    $safeName = ("${name}_$reference") -replace '[/:@]', '_'
    $workDir = Join-Path $script:OutputRoot $safeName
    $blobDir = Join-Path $workDir "blobs\sha256"
    $blobDir = $blobDir -replace '\\', [IO.Path]::DirectorySeparatorChar
    New-Item -ItemType Directory -Path $blobDir -Force | Out-Null

    Write-Host "Fetching manifest for $registry/${name}:$reference" -ForegroundColor Cyan
    $digest = Save-Manifest $name $reference $blobDir
    $manifest = Read-Blob $digest $blobDir

    # Multi-platform image: pick the manifest that matches -Platform
    if ($manifest.manifests) {
        $os, $arch, $variant = $Platform -split '/'
        $match = @($manifest.manifests | Where-Object {
                $_.platform.os -eq $os -and $_.platform.architecture -eq $arch -and
                (-not $variant -or $_.platform.variant -eq $variant)
            })

        if ($match.Count -eq 0) {
            $available = ($manifest.manifests | Where-Object { $_.platform.os -ne 'unknown' } |
                ForEach-Object { "$($_.platform.os)/$($_.platform.architecture)" }) -join ', '
            throw "No $Platform build found. Available: $available"
        }

        $digest = Save-Manifest $name $match[0].digest $blobDir
        $manifest = Read-Blob $digest $blobDir
    }

    $blobs = @($manifest.config) + @($manifest.layers)
    $count = 0
    foreach ($blob in $blobs) {
        $count++
        $sizeMb = [math]::Round($blob.size / 1MB, 1)
        Write-Host "  [$count/$($blobs.Count)] $($blob.digest.Substring(7, 12)) ($sizeMb MB)"
        $url = "https://$registry/v2/$name/blobs/$($blob.digest)"
        [void](Save-VerifiedBlob -Repository $name -Url $url -ExpectedDigest $blob.digest -BlobDir $blobDir)
    }

    # Add the metadata that makes the folder a valid OCI layout and loadable by Docker
    $imageName = if ($reference -like "sha256:*") { "$registry/$name" } else { "$registry/${name}:$reference" }
    $manifestPath = Join-Path $blobDir ($digest -replace '^sha256:', '')
    $mediaType = if ($manifest.mediaType) { $manifest.mediaType } else { "application/vnd.oci.image.manifest.v1+json" }

    $index = @{
        schemaVersion = 2
        mediaType     = "application/vnd.oci.image.index.v1+json"
        manifests     = @(@{
                mediaType   = $mediaType
                digest      = $digest
                size        = (Get-Item -LiteralPath $manifestPath).Length
                annotations = @{ "io.containerd.image.name" = $imageName }
            })
    }

    # Assigned this way because an "if" expression would turn a one-item array into a string
    $repoTags = @()
    if ($reference -notlike "sha256:*") { $repoTags = @($imageName) }
    $dockerManifest = @{
        Config   = "blobs/sha256/" + ($manifest.config.digest -replace '^sha256:', '')
        RepoTags = @($repoTags)
        Layers   = @($manifest.layers | ForEach-Object { "blobs/sha256/" + ($_.digest -replace '^sha256:', '') })
    }

    Write-TextFile (Join-Path $workDir "oci-layout") '{"imageLayoutVersion":"1.0.0"}'
    Write-TextFile (Join-Path $workDir "index.json") ($index | ConvertTo-Json -Depth 6 -Compress)
    Write-TextFile (Join-Path $workDir "manifest.json") ("[" + ($dockerManifest | ConvertTo-Json -Depth 6 -Compress) + "]")

    $tarPath = Join-Path $script:OutputRoot "$safeName.tar"
    & tar -cf $tarPath -C $workDir oci-layout index.json manifest.json blobs
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

    Remove-Item -LiteralPath $workDir -Recurse -Force
    Write-Host "Saved $tarPath" -ForegroundColor Green
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$script:OutputRoot = (Resolve-Path -LiteralPath $OutputDir).Path

$failed = @()
foreach ($image in $Images) {
    try {
        Get-Image $image
    }
    catch {
        Write-Warning "Failed to download ${image}: $($_.Exception.Message)"
        $failed += $image
    }
}

if ($failed.Count -gt 0) {
    Write-Warning "Finished with errors: $($failed -join ', ')"
    exit 1
}

Write-Host "All images downloaded." -ForegroundColor Green
