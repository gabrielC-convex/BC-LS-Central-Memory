<#
.SYNOPSIS
    Lists the extensions installed on the LSRetail2 environment.

.DESCRIPTION
    The versions declared in app.json "dependencies" must be met by what is
    actually installed on the tenant, and the NuGet feed is not authoritative for
    that. This prints the real versions so the dependency entries can be pinned
    against them.

.EXAMPLE
    pwsh ./tools/Get-LSRetail2Extensions.ps1

.EXAMPLE
    pwsh ./tools/Get-LSRetail2Extensions.ps1 -Filter 'LS Retail'
#>
[CmdletBinding()]
param(
    # Substring matched against publisher or name; omit to list everything.
    [string] $Filter
)

$ErrorActionPreference = 'Stop'
Import-Module BcContainerHelper -Force -WarningAction SilentlyContinue

$repoRoot    = Split-Path $PSScriptRoot -Parent
$envJson     = Get-Content "$repoRoot\environments\LSRetail2.json" -Raw | ConvertFrom-Json
$environment = $envJson.environmentName
if ($envJson.environmentUrl -notmatch '/([0-9a-fA-F-]{36})/') {
    throw "Cannot read the tenant id out of environmentUrl: $($envJson.environmentUrl)"
}
$tenantId = $Matches[1]

$cacheFile = "$env:USERPROFILE\.bc-auth-lsretail2.json"
$authContext = $null
if (Test-Path $cacheFile) {
    try {
        $cached = Get-Content $cacheFile -Raw | ConvertFrom-Json
        $authContext = New-BcAuthContext -tenantID $tenantId -refreshToken $cached.refreshToken
    }
    catch { $authContext = $null }
}
if (-not $authContext) {
    $authContext = New-BcAuthContext -tenantID $tenantId -includeDeviceLogin
    $authContext | ConvertTo-Json | Set-Content $cacheFile
}

$apps = Get-BcInstalledExtensions -bcAuthContext $authContext -environment $environment
if ($Filter) {
    $apps = $apps | Where-Object { $_.publisher -like "*$Filter*" -or $_.displayName -like "*$Filter*" }
}

$apps |
    Select-Object @{n = 'Publisher'; e = { $_.publisher } },
                  @{n = 'Name'; e = { $_.displayName } },
                  @{n = 'Version'; e = { "$($_.versionMajor).$($_.versionMinor).$($_.versionBuild).$($_.versionRevision)" } },
                  @{n = 'State'; e = { $_.state } },
                  @{n = 'Id'; e = { $_.id } } |
    Sort-Object Publisher, Name |
    Format-Table -AutoSize
