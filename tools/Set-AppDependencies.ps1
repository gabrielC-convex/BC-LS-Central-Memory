<#
.SYNOPSIS
    Fills the "dependencies" array in app/app.json from the symbol packages
    already downloaded into app/.alpackages.

.DESCRIPTION
    Extending an LS Central object (e.g. page 99001452 "LSC Retail Item List")
    requires an explicit dependency entry in app.json, and that entry needs the
    LS Central app GUID. The GUID is not visible in the .app file name, so this
    script reads it out of each package's NavxManifest.xml.

    A .app file is a ZIP archive behind a small proprietary header, so the
    payload is copied out to a temp file starting at the ZIP signature and read
    from there. The copy is streamed, so package size does not matter.

    Microsoft platform packages (System Application, Base Application, ...) are
    skipped on purpose: they are covered by "platform"/"application" in app.json.

.EXAMPLE
    pwsh ./tools/Set-AppDependencies.ps1

.EXAMPLE
    pwsh ./tools/Set-AppDependencies.ps1 -DryRun
#>
[CmdletBinding()]
param(
    # AL project folder (the one holding app.json and .alpackages).
    [string] $AppFolder = (Join-Path (Join-Path $PSScriptRoot '..') 'app'),

    # Publishers to skip; their objects are available without a dependency entry.
    [string[]] $ExcludePublishers = @('Microsoft'),

    # Print the resulting dependencies without writing app.json.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-NavxManifest {
    param([Parameter(Mandatory)][string] $AppFilePath)

    $stream = [System.IO.File]::OpenRead($AppFilePath)
    $tempZip = $null
    try {
        # Locate the local file header ("PK\x03\x04") that starts the ZIP payload.
        $header = New-Object byte[] 4096
        $read = $stream.Read($header, 0, $header.Length)
        $offset = -1
        for ($i = 0; $i -le $read - 4; $i++) {
            if ($header[$i] -eq 0x50 -and $header[$i + 1] -eq 0x4B -and
                $header[$i + 2] -eq 0x03 -and $header[$i + 3] -eq 0x04) {
                $offset = $i
                break
            }
        }
        if ($offset -lt 0) {
            Write-Warning "No ZIP payload found in $(Split-Path $AppFilePath -Leaf) - skipped."
            return $null
        }

        $tempZip = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$([guid]::NewGuid()).zip")
        $stream.Position = $offset
        $out = [System.IO.File]::Create($tempZip)
        try { $stream.CopyTo($out) } finally { $out.Dispose() }

        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq 'NavxManifest.xml' } | Select-Object -First 1
            if (-not $entry) {
                Write-Warning "No NavxManifest.xml in $(Split-Path $AppFilePath -Leaf) - skipped."
                return $null
            }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { [xml] $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $zip.Dispose() }
    }
    finally {
        $stream.Dispose()
        if ($tempZip -and (Test-Path $tempZip)) { Remove-Item $tempZip -Force }
    }
}

$AppFolder = (Resolve-Path $AppFolder).Path
$appJsonPath = Join-Path $AppFolder 'app.json'
$packagesPath = Join-Path $AppFolder '.alpackages'

if (-not (Test-Path $appJsonPath)) { throw "app.json not found at $appJsonPath" }
if (-not (Test-Path $packagesPath)) {
    throw "$packagesPath not found. Run 'AL: Download Symbols' in VS Code first."
}

$packages = Get-ChildItem -Path $packagesPath -Filter '*.app' -File
if (-not $packages) { throw "No .app symbol packages in $packagesPath." }

$dependencies = @()
foreach ($package in $packages) {
    $manifest = Get-NavxManifest -AppFilePath $package.FullName
    if (-not $manifest) { continue }

    $app = $manifest.Package.App
    if ($ExcludePublishers -contains $app.Publisher) {
        Write-Verbose "Skipping $($app.Publisher) / $($app.Name)"
        continue
    }

    Write-Host ("Found {0} / {1} {2}  ({3})" -f $app.Publisher, $app.Name, $app.Version, $app.Id)
    $dependencies += [ordered] @{
        id        = $app.Id
        name      = $app.Name
        publisher = $app.Publisher
        version   = $app.Version
    }
}

if (-not $dependencies) {
    throw "No third-party symbol packages found - is LS Central installed on the environment you downloaded symbols from?"
}

$appJson = Get-Content $appJsonPath -Raw | ConvertFrom-Json
# Drop the app's own id in case its symbols ended up in .alpackages.
$dependencies = @($dependencies | Where-Object { $_.id -ne $appJson.id })

if ($DryRun) {
    $dependencies | ConvertTo-Json -Depth 5
    return
}

$appJson | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue $dependencies -Force
$appJson | ConvertTo-Json -Depth 10 | Set-Content $appJsonPath -Encoding utf8
Write-Host "Wrote $($dependencies.Count) dependency entries to $appJsonPath"
