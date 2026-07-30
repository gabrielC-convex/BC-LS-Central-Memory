<#
.SYNOPSIS
    Publică sistemul de search (kb/ + tools/) în repo-ul lui dedicat:
    git@github.com:gabrielC-convex/BC-LS-Central-Memory.git

.DESCRIPTION
    Workspace-ul are origin = ConvexNetwork/Lensa, iar acolo pleacă DOAR aplicația
    (filtrarea o face .gitignore: kb/, tools/ și restul nu sunt urmărite de git).
    Acest script acoperă al doilea proiect: ia kb/ + tools/ din starea curentă de pe disc,
    face un snapshot-commit într-un repo temporar și îl împinge forțat în Memory.

    Repo-ul Memory e artefact generat (force-push, un commit per sincronizare) —
    nu se comite direct în el.

.EXAMPLE
    pwsh ./tools/Sync-Mirrors.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$url  = 'git@github.com:gabrielC-convex/BC-LS-Central-Memory.git'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sync-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    foreach ($d in @('kb', 'tools')) {
        Copy-Item -Recurse -Path (Join-Path $root $d) -Destination (Join-Path $tmp $d)
    }
    # curățenie: nimic derivat sau temporar în repo-ul de cunoștințe
    Get-ChildItem $tmp -Recurse -Include '*.sqlite', '__pycache__' -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force

    Push-Location $tmp
    try {
        git init -q -b main
        git config user.name  (git -C $root config user.name)
        git config user.email (git -C $root config user.email)
        git add -A
        git commit -q -m "sync from workspace $(Get-Date -Format yyyy-MM-dd)"
        git push --force $url HEAD:main
        Write-Host "OK -> gabrielC-convex/BC-LS-Central-Memory"
        Write-Host ("   " + (git ls-remote $url refs/heads/main))
    }
    finally { Pop-Location }
}
finally { Remove-Item -Recurse -Force $tmp }
