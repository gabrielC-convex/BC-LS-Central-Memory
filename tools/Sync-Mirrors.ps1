<#
.SYNOPSIS
    Two-way sync of the knowledge system (kb/ + tools/) with its own repo:
    git@github.com:gabrielC-convex/BC-LS-Central-Memory.git

.DESCRIPTION
    kb/ and tools/ are shared by several workspaces (Lensa, bc-lscentral-bat-starter, ...).
    Each workspace has its own origin and does NOT track kb/ or tools/ in it — the knowledge
    repo is their single source of truth.

    This used to force-push a snapshot of the local state, which meant the last workspace to
    sync silently destroyed whatever the other one had written. It now merges instead:

      1. clone the knowledge repo into a temp dir           (everything both sides have)
      2. copy the local kb/ + tools/ over it                (our additions and edits win)
      3. commit + push WITHOUT --force                      (rejected if someone pushed meanwhile)
      4. copy the merged result back into the workspace     (we end up holding everything)

    Union semantics: a file that exists only on the remote survives, because step 2 copies
    over the clone instead of replacing it. The trade-off is that DELETIONS do not propagate —
    to remove a fact, delete it in the knowledge repo directly.

.EXAMPLE
    pwsh ./tools/Sync-Mirrors.ps1
.EXAMPLE
    pwsh ./tools/Sync-Mirrors.ps1 -PullOnly   # just take what the other workspaces published
#>
[CmdletBinding()]
param(
    [switch]$PullOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$url  = 'git@github.com:gabrielC-convex/BC-LS-Central-Memory.git'
$dirs = @('kb', 'tools')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kbsync-" + [guid]::NewGuid().ToString('N'))
try {
    git clone -q $url $tmp
    if ($LASTEXITCODE -ne 0) { throw "clone failed: $url" }

    if (-not $PullOnly) {
        # ours wins per file; files only present remotely are left untouched
        foreach ($d in $dirs) {
            $src = Join-Path $root $d
            if (Test-Path $src) { Copy-Item -Recurse -Force -Path $src -Destination $tmp }
        }
        # derived artifacts never belong in the knowledge repo
        Get-ChildItem $tmp -Recurse -Include '*.sqlite', '__pycache__' -Force -EA SilentlyContinue |
            Remove-Item -Recurse -Force

        Push-Location $tmp
        try {
            git add -A
            if (git status --porcelain) {
                # A workspace may have no identity configured — normal commits there still work
                # because git derives one from user@host, but `git config user.name` returns
                # empty and `commit` then dies with "empty ident name". Fall back explicitly.
                $who   = (git -C $root config user.name)  ; if (-not $who)   { $who   = (git config --global user.name) }
                $email = (git -C $root config user.email) ; if (-not $email) { $email = (git config --global user.email) }
                if (-not $who)   { $who   = "$env:USERNAME" }
                if (-not $email) { $email = "$env:USERNAME@$env:COMPUTERNAME" }

                git -c user.name="$who" -c user.email="$email" `
                    commit -q -m "sync from $(Split-Path $root -Leaf) $(Get-Date -Format yyyy-MM-dd)"
                if ($LASTEXITCODE -ne 0) { throw "commit failed in the knowledge repo - nothing was published." }

                git push -q origin HEAD:main
                if ($LASTEXITCODE -ne 0) {
                    throw "push rejected - someone published meanwhile. Re-run this script; it re-clones and re-merges."
                }
                Write-Host "pushed to BC-LS-Central-Memory as $who <$email>" -ForegroundColor Green
            }
            else { Write-Host "nothing local to publish" -ForegroundColor Gray }
        }
        finally { Pop-Location }
    }

    # bring the merged state back - this is the half that was missing before
    foreach ($d in $dirs) {
        $src = Join-Path $tmp $d
        if (Test-Path $src) { Copy-Item -Recurse -Force -Path $src -Destination $root }
    }
    Write-Host "workspace now holds the merged kb/ + tools/" -ForegroundColor Green
    Write-Host "run 'python tools/kb.py index' to refresh the search index" -ForegroundColor Gray
}
finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -EA SilentlyContinue }
}
