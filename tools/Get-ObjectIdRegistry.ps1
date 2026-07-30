<#
.SYNOPSIS
    Regenerează registrul de ID-uri de obiecte AL (ce e ocupat, ce mai e liber).

.DESCRIPTION
    Scanează recursiv fișierele .al din folderele primite ca parametru, extrage
    declarațiile de obiecte AL (tip + ID + nume + fișier + linie), citește
    idRanges din app.json-urile găsite și calculează, pe fiecare tip de obiect,
    ID-urile ocupate și cele libere din range.

    Regula pe care se bazează calculul: unicitatea ID-urilor este PER TIP DE
    OBIECT, nu globală — `table 50100` și `tableextension 50100` pot coexista.
    Domeniul de unicitate este însă TENANT-ul, nu proiectul: de aceea scriptul
    scanează implicit ambele repo-uri BAT care declară același range, iar
    ID-urile libere se calculează pe reuniunea lor, nu pe fiecare separat.
    Detaliile și nivelul de încredere sunt scrise pe pagina generată.

    Scrie două ieșiri în docs/object-registry/:
      registry.json  — datele brute (obiecte, range-uri, liber/ocupat, coliziuni)
      index.html     — pagina de consultat, self-contained (fără CDN, fără fetch)

    Nu are nevoie de module externe. Testat pe PowerShell 7.6.

.PARAMETER Path
    Folderele scanate recursiv după fișiere .al. Implicit: folderul app/ al
    acestui repo plus app/ din repo-ul soră bc-lscentral-bat-starter.
    Folderele inexistente sunt sărite, cu avertisment.

.PARAMETER OutputDirectory
    Unde se scriu registry.json și index.html. Implicit: docs/object-registry/
    din rădăcina acestui repo. Ignorat când se folosește -Json.

.PARAMETER Json
    Scoate doar datele, ca JSON, la stdout. Nu scrie niciun fișier pe disc.
    Util pentru pipe către jq sau ConvertFrom-Json.

.EXAMPLE
    pwsh ./tools/Get-ObjectIdRegistry.ps1

    Regenerează docs/object-registry/registry.json și index.html cu folderele implicite.

.EXAMPLE
    pwsh ./tools/Get-ObjectIdRegistry.ps1 -Json | ConvertFrom-Json | Select-Object -Expand byType |
        Select-Object type, nextFree

    Primul ID liber pentru fiecare tip de obiect, fără să atingă discul.

.EXAMPLE
    pwsh ./tools/Get-ObjectIdRegistry.ps1 -Path ./app -OutputDirectory ./docs/registru-local

    Scanează doar app-ul acestui repo. Atenție: ID-urile raportate ca libere
    NU mai țin cont de repo-ul soră, deci nu folosi varianta asta ca să aloci ID-uri noi.

.NOTES
    Ce NU face scriptul:
      - nu interoghează tenantul LSRetail2; nu vede obiectele altor extensii instalate
      - nu citește base app-ul sau LS Central; range-ul 50100-50149 e prin convenție
        rezervat PTE-urilor, dar scriptul nu poate verifica asta
      - nu compilează nimic; nu înlocuiește un build
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Path,

    [string] $OutputDirectory,

    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# Constante
# ---------------------------------------------------------------------------

# Tipurile de obiect AL care au ID numeric. Ordinea contează pentru afișare.
# Cele fără ID (profile, entitlement, controladdin, interface, pagecustomization)
# lipsesc intenționat — nu ocupă nimic dintr-un range.
$script:ObjectTypes = @(
    'table', 'tableextension',
    'page', 'pageextension',
    'codeunit',
    'report', 'reportextension',
    'query', 'xmlport',
    'enum', 'enumextension',
    'permissionset', 'permissionsetextension'
)

# Foldere sărite la scanare (simboluri descărcate, artefacte de build, cache).
$script:SkipFolders = @('.alpackages', '.altestrunner', '.snapshots', '.git', 'node_modules', 'bin', 'obj', 'out', 'output')

# Alternativele sunt ordonate cu cel mai lung prefix primul, ca `tableextension`
# să nu fie citit ca `table`. Numele de obiect poate fi între ghilimele duble
# (cu "" ca escape) sau un identificator simplu.
$script:ObjectRegex = [regex]::new(
    '(?im)^[ \t]*(?<type>tableextension|table|pageextension|page|codeunit|reportextension|report|query|xmlport|enumextension|enum|permissionsetextension|permissionset)[ \t]+(?<id>\d+)[ \t]+(?<name>"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_]*)(?:[ \t]+extends[ \t]+(?<base>"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_]*))?'
)

# Tokenizer pentru string-uri și comentarii. Ordinea alternativelor garantează
# că un `//` dintr-un string literal nu e confundat cu un comentariu.
$script:CommentRegex = [regex]::new(
    "(?s)('(?:[^']|'')*')|(""(?:[^""]|"""")*"")|(//[^\r\n]*)|(/\*.*?\*/)"
)

# ---------------------------------------------------------------------------
# Funcții
# ---------------------------------------------------------------------------

function Remove-AlComment {
    <#
    .SYNOPSIS
        Înlocuiește comentariile AL cu spații, păstrând lungimea și numerele de linie.
    .DESCRIPTION
        Necesar pentru că în repo există comentarii care conțin declarații de
        obiecte, de exemplu:
            // 50149 deliberately: bc-lscentral-bat-starter already ships pageextension 50100.
        Fără curățare, linia asta ar produce un obiect fantomă și o coliziune falsă.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    return $script:CommentRegex.Replace($Text, {
            param($m)
            # Grupurile 1 și 2 sunt string / identificator între ghilimele: se păstrează.
            if ($m.Groups[1].Success -or $m.Groups[2].Success) { return $m.Value }
            # Comentariu: se golește, dar se păstrează newline-urile.
            return ($m.Value -replace '[^\r\n]', ' ')
        })
}

function ConvertFrom-AlIdentifier {
    <#
    .SYNOPSIS
        Scoate ghilimelele exterioare dintr-un identificator AL și de-escapează `""`.
    .DESCRIPTION
        Un `.Trim('"')` naiv strică două cazuri reale:
          "Has ""Escaped"" Quotes"  -> ar lăsa ghilimelele duble pe dinăuntru
          "Ends With Quote"""       -> ar tăia și ghilimeaua care face parte din nume
        Identificatorii fără ghilimele sunt întorși neatinși.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    if ($Value.Length -ge 2 -and $Value.StartsWith('"') -and $Value.EndsWith('"')) {
        return $Value.Substring(1, $Value.Length - 2).Replace('""', '"')
    }
    return $Value
}

function Get-AlObjectFromFile {
    <#
    .SYNOPSIS
        Extrage declarațiile de obiecte AL dintr-un fișier .al.
    #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $RepoName,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    $clean = Remove-AlComment -Text $raw
    $relative = $FilePath
    if ($FilePath.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $FilePath.Substring($RepoRoot.Length).TrimStart('\', '/')
    }

    foreach ($m in $script:ObjectRegex.Matches($clean)) {
        $line = ($clean.Substring(0, $m.Index) -split "`n").Count

        [pscustomobject]@{
            repo         = $RepoName
            type         = $m.Groups['type'].Value.ToLowerInvariant()
            id           = [int] $m.Groups['id'].Value
            name         = ConvertFrom-AlIdentifier -Value $m.Groups['name'].Value
            extends      = if ($m.Groups['base'].Success) { ConvertFrom-AlIdentifier -Value $m.Groups['base'].Value } else { $null }
            file         = $FilePath
            relativeFile = ($relative -replace '\\', '/')
            line         = $line
        }
    }
}

function Get-RepoRoot {
    <#
    .SYNOPSIS
        Urcă din folderul dat până găsește un .git; altfel întoarce folderul părinte.
    #>
    param([Parameter(Mandatory)][string] $StartPath)

    $current = Get-Item -LiteralPath $StartPath
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName '.git')) { return $current.FullName }
        $current = $current.Parent
    }
    return (Split-Path -Parent $StartPath)
}

function Get-AppManifest {
    <#
    .SYNOPSIS
        Citește app.json din folderul scanat și din rădăcina repo-ului.
    .DESCRIPTION
        Nu caută recursiv: un app.json rătăcit prin .alpackages sau printr-un
        sub-proiect de test ar polua range-urile. Repo-ul soră are două manifeste
        (rădăcină + app/); ambele sunt raportate, ca duplicatul să fie vizibil.
    #>
    param(
        [Parameter(Mandatory)][string] $ScanPath,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $candidates = @(
        (Join-Path $ScanPath 'app.json'),
        (Join-Path $RepoRoot 'app.json')
    ) | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }

        try {
            $manifest = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Warning "app.json nevalid, sărit: $candidate ($($_.Exception.Message))"
            continue
        }

        $ranges = @()
        if ($manifest.PSObject.Properties.Name -contains 'idRanges' -and $manifest.idRanges) {
            foreach ($r in $manifest.idRanges) { $ranges += [pscustomobject]@{ from = [int] $r.from; to = [int] $r.to } }
        }
        elseif ($manifest.PSObject.Properties.Name -contains 'idRange' -and $manifest.idRange) {
            $ranges += [pscustomobject]@{ from = [int] $manifest.idRange.from; to = [int] $manifest.idRange.to }
        }

        [pscustomobject]@{
            name      = $manifest.name
            appId     = $manifest.id
            publisher = $manifest.publisher
            version   = $manifest.version
            target    = if ($manifest.PSObject.Properties.Name -contains 'target') { $manifest.target } else { $null }
            file      = $candidate
            ranges    = $ranges
        }
    }
}

function Test-InRange {
    param(
        [Parameter(Mandatory)][int] $Id,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Ranges
    )
    foreach ($r in $Ranges) { if ($Id -ge $r.from -and $Id -le $r.to) { return $true } }
    return $false
}

function ConvertTo-JsonSafeForHtml {
    <#
    .SYNOPSIS
        JSON cu `<` escapat, ca să nu poată închide accidental blocul <script>.
    #>
    param([Parameter(Mandatory)] $InputObject)
    return ($InputObject | ConvertTo-Json -Depth 12 -Compress).Replace('<', '\u003c')
}

# ---------------------------------------------------------------------------
# 1. Rezolvarea parametrilor
# ---------------------------------------------------------------------------

$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $Path -or $Path.Count -eq 0) {
    $Path = @(
        (Join-Path $repoRoot 'app'),
        'C:\localhost\bc-lscentral-bat-starter\app'
    )
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot 'docs\object-registry'
}

$scanPaths = @()
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p -PathType Container)) {
        Write-Warning "Folder inexistent, sărit: $p"
        continue
    }
    $scanPaths += (Resolve-Path -LiteralPath $p).ProviderPath.TrimEnd('\', '/')
}
$scanPaths = @($scanPaths | Select-Object -Unique)

if ($scanPaths.Count -eq 0) {
    throw 'Niciun folder valid de scanat. Verifică parametrul -Path.'
}

# ---------------------------------------------------------------------------
# 2. Scanarea
# ---------------------------------------------------------------------------

$objects = [System.Collections.Generic.List[object]]::new()
$repos = [System.Collections.Generic.List[object]]::new()
$seenFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($scanPath in $scanPaths) {
    $thisRepoRoot = Get-RepoRoot -StartPath $scanPath
    $repoName = Split-Path $thisRepoRoot -Leaf

    Write-Verbose "Scanez $scanPath (repo: $repoName)"

    $alFiles = Get-ChildItem -LiteralPath $scanPath -Recurse -File -Filter '*.al' |
        Where-Object {
            $segments = $_.FullName.Substring($scanPath.Length).Split([char[]]('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
            -not ($segments | Where-Object { $script:SkipFolders -contains $_ })
        }

    $fileCount = 0
    foreach ($file in $alFiles) {
        if (-not $seenFiles.Add($file.FullName)) {
            Write-Verbose "Fișier deja scanat prin alt -Path, sărit: $($file.FullName)"
            continue
        }
        $fileCount++
        foreach ($obj in (Get-AlObjectFromFile -FilePath $file.FullName -RepoName $repoName -RepoRoot $thisRepoRoot)) {
            $objects.Add($obj)
        }
    }

    $apps = @(Get-AppManifest -ScanPath $scanPath -RepoRoot $thisRepoRoot)
    if ($apps.Count -eq 0) {
        Write-Warning "Niciun app.json găsit pentru $scanPath - range-urile acestui repo lipsesc din calcul."
    }

    $existing = $repos | Where-Object { $_.root -eq $thisRepoRoot }
    if ($existing) {
        $existing.paths += $scanPath
        $existing.fileCount += $fileCount
    }
    else {
        $repos.Add([pscustomobject]@{
                name      = $repoName
                root      = $thisRepoRoot
                paths     = @($scanPath)
                fileCount = $fileCount
                apps      = $apps
            })
    }
}

# ---------------------------------------------------------------------------
# 3. Range-uri
# ---------------------------------------------------------------------------

$allRanges = [System.Collections.Generic.List[object]]::new()
foreach ($repo in $repos) {
    foreach ($app in $repo.apps) {
        foreach ($r in $app.ranges) {
            $allRanges.Add([pscustomobject]@{
                    repo      = $repo.name
                    appName   = $app.name
                    appId     = $app.appId
                    version   = $app.version
                    manifest  = ($app.file -replace '\\', '/')
                    from      = $r.from
                    to        = $r.to
                })
        }
    }
}

if ($allRanges.Count -eq 0) {
    throw 'Niciun idRange găsit în app.json-urile scanate. Fără range nu se poate calcula ce e liber.'
}

# Reuniunea range-urilor declarate = spațiul în care se caută ID-uri libere.
$rangeIds = [System.Collections.Generic.SortedSet[int]]::new()
foreach ($r in $allRanges) {
    for ($i = $r.from; $i -le $r.to; $i++) { [void] $rangeIds.Add($i) }
}
$rangeIdList = @($rangeIds)

# Același app id declarat în mai multe app.json = manifest duplicat sau orfan.
# Nu strică nimic direct, dar e o sursă clasică de confuzie: nu se mai știe pe
# care manifest lucrează build-ul.
$duplicateManifests = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($allRanges | Group-Object appId)) {
    $manifests = @($group.Group | Select-Object -ExpandProperty manifest -Unique)
    if ($manifests.Count -gt 1) {
        $duplicateManifests.Add([pscustomobject]@{
                appName   = $group.Group[0].appName
                appId     = $group.Name
                manifests = $manifests
            })
    }
}

# Două app-uri DIFERITE care declară intervale suprapuse = risc de conflict la
# instalarea ambelor pe același tenant. Se raportează, nu se ascunde.
$rangeOverlaps = [System.Collections.Generic.List[object]]::new()
$distinctApps = @($allRanges | Group-Object appId)
if ($distinctApps.Count -gt 1) {
    for ($i = 0; $i -lt $distinctApps.Count; $i++) {
        for ($j = $i + 1; $j -lt $distinctApps.Count; $j++) {
            # Intervalele se deduplică întâi: același app declarat în două
            # manifeste identice ar produce altfel aceeași suprapunere de mai multe ori.
            $aRanges = @($distinctApps[$i].Group | Group-Object { "$($_.from)-$($_.to)" } | ForEach-Object { $_.Group[0] })
            $bRanges = @($distinctApps[$j].Group | Group-Object { "$($_.from)-$($_.to)" } | ForEach-Object { $_.Group[0] })

            foreach ($a in $aRanges) {
                foreach ($b in $bRanges) {
                    $from = [Math]::Max($a.from, $b.from)
                    $to = [Math]::Min($a.to, $b.to)
                    if ($from -le $to) {
                        $rangeOverlaps.Add([pscustomobject]@{
                                appA = "$($a.appName) ($($a.repo))"
                                appB = "$($b.appName) ($($b.repo))"
                                from = $from
                                to   = $to
                            })
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Ocupat / liber pe tip
# ---------------------------------------------------------------------------

$byType = [System.Collections.Generic.List[object]]::new()
foreach ($type in $script:ObjectTypes) {
    $used = @($objects | Where-Object { $_.type -eq $type })
    $usedIds = @($used | Select-Object -ExpandProperty id -Unique | Sort-Object)
    $freeIds = @($rangeIdList | Where-Object { $_ -notin $usedIds })

    $byType.Add([pscustomobject]@{
            type       = $type
            usedCount  = $usedIds.Count
            freeCount  = $freeIds.Count
            usedIds    = $usedIds
            freeIds    = $freeIds
            nextFree   = if ($freeIds.Count -gt 0) { $freeIds[0] } else { $null }
        })
}

# ---------------------------------------------------------------------------
# 5. Coliziuni și obiecte în afara range-ului
# ---------------------------------------------------------------------------

# Coliziune = același tip + același ID declarat de mai mult de un obiect.
# În același repo înseamnă că nu compilează; între repo-uri înseamnă că cele
# două app-uri nu pot sta simultan pe același tenant.
$collisions = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($objects | Group-Object { "$($_.type)|$($_.id)" })) {
    if ($group.Count -le 1) { continue }

    $reposInvolved = @($group.Group | Select-Object -ExpandProperty repo -Unique)
    $collisions.Add([pscustomobject]@{
            type      = $group.Group[0].type
            id        = $group.Group[0].id
            scope     = if ($reposInvolved.Count -gt 1) { 'între repo-uri' } else { 'în același repo' }
            severity  = if ($reposInvolved.Count -gt 1) { 'conflict la instalare pe același tenant' } else { 'nu compilează' }
            occurrences = @($group.Group | ForEach-Object {
                    [pscustomobject]@{ repo = $_.repo; name = $_.name; file = $_.relativeFile; line = $_.line }
                })
        })
}

$outOfRange = [System.Collections.Generic.List[object]]::new()
foreach ($obj in $objects) {
    $repoRanges = @($allRanges | Where-Object { $_.repo -eq $obj.repo })
    if ($repoRanges.Count -eq 0) { continue }   # repo fără manifest: nu avem cu ce compara

    if (-not (Test-InRange -Id $obj.id -Ranges $repoRanges)) {
        $outOfRange.Add([pscustomobject]@{
                repo = $obj.repo
                type = $obj.type
                id   = $obj.id
                name = $obj.name
                file = $obj.relativeFile
                line = $obj.line
                declaredRanges = @($repoRanges | ForEach-Object { "$($_.from)-$($_.to)" } | Select-Object -Unique)
            })
    }
}

# ---------------------------------------------------------------------------
# 6. Asamblarea rezultatului
# ---------------------------------------------------------------------------

$commandLine = 'pwsh ./tools/Get-ObjectIdRegistry.ps1'
if ($PSBoundParameters.ContainsKey('Path')) {
    $commandLine += ' -Path ' + (($Path | ForEach-Object { "'$_'" }) -join ', ')
}
if ($PSBoundParameters.ContainsKey('OutputDirectory')) {
    $commandLine += " -OutputDirectory '$OutputDirectory'"
}

$now = Get-Date
$registry = [pscustomobject]@{
    generatedAt    = $now.ToString('yyyy-MM-dd HH:mm')
    generatedAtIso = $now.ToString('o')
    command        = $commandLine
    scannedPaths   = @($scanPaths | ForEach-Object { $_ -replace '\\', '/' })
    objectTypes    = $script:ObjectTypes
    rangeMin       = $rangeIdList[0]
    rangeMax       = $rangeIdList[-1]
    rangeIds       = $rangeIdList
    ranges         = @($allRanges)
    rangeOverlaps  = @($rangeOverlaps)
    duplicateManifests = @($duplicateManifests)
    repos          = @($repos | ForEach-Object {
            [pscustomobject]@{
                name      = $_.name
                root      = ($_.root -replace '\\', '/')
                paths     = @($_.paths | ForEach-Object { $_ -replace '\\', '/' })
                fileCount = $_.fileCount
                apps      = @($_.apps | ForEach-Object {
                        [pscustomobject]@{
                            name      = $_.name
                            appId     = $_.appId
                            publisher = $_.publisher
                            version   = $_.version
                            target    = $_.target
                            manifest  = ($_.file -replace '\\', '/')
                            ranges    = @($_.ranges)
                        }
                    })
            }
        })
    objects        = @($objects | Sort-Object type, id, repo | ForEach-Object {
            [pscustomobject]@{
                repo         = $_.repo
                type         = $_.type
                id           = $_.id
                name         = $_.name
                extends      = $_.extends
                file         = ($_.file -replace '\\', '/')
                relativeFile = $_.relativeFile
                line         = $_.line
            }
        })
    byType         = @($byType)
    collisions     = @($collisions)
    outOfRange     = @($outOfRange)
    stats          = [pscustomobject]@{
        objectCount    = $objects.Count
        repoCount      = $repos.Count
        fileCount      = $seenFiles.Count
        typesUsed      = @($byType | Where-Object { $_.usedCount -gt 0 }).Count
        rangeSize      = $rangeIdList.Count
        collisionCount = $collisions.Count
        outOfRangeCount = $outOfRange.Count
    }
}

if ($Json) {
    $registry | ConvertTo-Json -Depth 12
    return
}

# ---------------------------------------------------------------------------
# 7. Scrierea ieșirilor
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'registry.json'
$htmlPath = Join-Path $OutputDirectory 'index.html'

$registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$template = @'
<!DOCTYPE html>
<html lang="ro">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Registru ID-uri obiecte AL — BAT LSC PTE</title>
<style>
/* Token-uri inline, ca pagina sa fie self-contained (fara CDN, fara link extern).
   Paleta e in acelasi registru cu Documentation/site/assets/style.css, dar NU e
   importata de acolo: aici sunt valori hex fixe, acolo sunt token-uri oklch.
   Pagina asta e deliberat doar light — nu are variante dark. De aceea declara
   explicit color-scheme: light, altfel pe un browser cu OS pe dark scrollbar-ul
   si popup-ul de <select> ar fi randate intunecat peste o pagina luminoasa.
   Nu edita aici: fisierul e regenerat de script. */
:root {
  color-scheme: light;
  --bg: #fafafa;
  --bg-card: #ffffff;
  --text: #18181b;
  --text-muted: #71717a;
  --text-soft: #a1a1aa;
  --border: #e4e4e7;
  --border-soft: #f1f1f3;
  --accent: #2563eb;
  --accent-soft: #dbeafe;
  --success: #16a34a;
  --success-bg: #f0fdf4;
  --warning: #d97706;
  --warning-bg: #fffbeb;
  --danger: #dc2626;
  --danger-bg: #fef2f2;
  --info: #0284c7;
  --info-bg: #f0f9ff;
  --mono: 'JetBrains Mono', 'SF Mono', Consolas, monospace;
  --max-w: 1100px;
  --topbar-h: 56px;
  /* Sloturi categorice pentru repo-uri. Validate impreuna: separare la daltonism
     pe toate perechile, plus contrast >= 4.5:1 cu textul alb, pentru ca celulele
     din harta poarta eticheta numerica peste culoare. Identitatea nu depinde
     niciodata doar de culoare — exista si legenda, si tabelul complet. */
  --repo-0: #2563eb;
  --repo-1: #c2410c;
  --repo-2: #047857;
}

* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: 'Inter', -apple-system, system-ui, sans-serif;
  background: var(--bg); color: var(--text);
  line-height: 1.65; font-size: 15px;
  -webkit-font-smoothing: antialiased;
}

.topbar {
  position: sticky; top: 0; z-index: 50;
  height: var(--topbar-h); padding: 0 24px;
  background: #09090b; color: #fff;
  display: flex; align-items: center; gap: 16px;
  border-bottom: 1px solid #27272a;
}
.topbar .brand { font-weight: 700; font-size: 14px; letter-spacing: -0.01em; color: #fff; }
.topbar .brand .accent { color: #a1a1aa; font-weight: 400; margin-left: 6px; }
.topbar .breadcrumb { flex: 1; font-size: 13px; color: #a1a1aa; }
.topbar .version {
  font-family: var(--mono); font-size: 12px; color: #71717a;
  background: rgba(255,255,255,.04); padding: 4px 10px; border-radius: 4px;
}

main { max-width: var(--max-w); margin: 0 auto; padding: 32px 24px 80px; }

h1 { font-size: 30px; font-weight: 700; margin: 0 0 8px; letter-spacing: -0.02em; }
.lead { font-size: 16px; color: var(--text-muted); margin: 0 0 28px; }
h2 {
  font-size: 22px; font-weight: 600; margin: 44px 0 14px;
  padding-bottom: 8px; border-bottom: 1px solid var(--border); letter-spacing: -0.015em;
}
h3 { font-size: 17px; font-weight: 600; margin: 26px 0 10px; }
p { margin: 10px 0; }
a { color: var(--accent); text-decoration: none; border-bottom: 1px solid transparent; }
a:hover { border-bottom-color: var(--accent); }

code {
  font-family: var(--mono); font-size: 13.5px;
  background: var(--border-soft); padding: 2px 6px; border-radius: 4px; color: #be185d;
}
pre {
  background: #0a0a0a; color: #e4e4e7; padding: 16px 18px;
  border-radius: 8px; overflow-x: auto; font-size: 13px; line-height: 1.55; margin: 16px 0;
}
pre code { padding: 0; background: transparent; color: inherit; }
ul, ol { padding-left: 24px; margin: 12px 0; }
li { margin: 6px 0; }

/* Tile-uri de sinteza */
.stats { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); margin: 0 0 8px; }
.stat {
  background: var(--bg-card); border: 1px solid var(--border);
  border-radius: 10px; padding: 14px 16px;
}
.stat .value { font-size: 26px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.2; }
.stat .label { font-size: 12px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.04em; margin-top: 2px; }
.stat.ok .value { color: var(--success); }
.stat.bad .value { color: var(--danger); }
.stat.range .value { font-size: 19px; font-family: var(--mono); letter-spacing: -0.01em; }

/* Callout-uri */
.callout {
  margin: 18px 0; padding: 14px 18px; border-radius: 8px;
  border-left: 4px solid; background: var(--bg-card); font-size: 14.5px;
}
.callout > strong:first-child {
  display: block; margin-bottom: 4px; font-size: 13px;
  text-transform: uppercase; letter-spacing: 0.04em;
}
.callout.warning { background: var(--warning-bg); border-color: var(--warning); }
.callout.warning > strong:first-child { color: var(--warning); }
.callout.success { background: var(--success-bg); border-color: var(--success); }
.callout.success > strong:first-child { color: var(--success); }
.callout.danger { background: var(--danger-bg); border-color: var(--danger); }
.callout.danger > strong:first-child { color: var(--danger); }
.callout.info { background: var(--info-bg); border-color: var(--info); }
.callout.info > strong:first-child { color: var(--info); }
.callout p { margin: 6px 0; }
.callout ul { margin: 6px 0; }

/* Harta range-ului */
.legend { display: flex; flex-wrap: wrap; gap: 16px; align-items: center; margin: 14px 0 18px; font-size: 13px; color: var(--text-muted); }
.legend .item { display: flex; align-items: center; gap: 7px; }
.legend .swatch { width: 14px; height: 14px; border-radius: 3px; border: 1px solid rgba(0,0,0,.08); flex: none; }

.map-type {
  background: var(--bg-card); border: 1px solid var(--border);
  border-radius: 10px; padding: 14px 16px; margin-bottom: 10px;
}
.map-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
.map-head .name { font-family: var(--mono); font-size: 14px; font-weight: 600; }
.map-head .counts { font-size: 12.5px; color: var(--text-muted); }
.map-head .next {
  margin-left: auto; font-size: 12px; font-family: var(--mono);
  background: var(--success-bg); color: var(--success);
  padding: 3px 9px; border-radius: 4px; font-weight: 600;
}
.map-row { display: flex; align-items: center; gap: 10px; margin-bottom: 4px; }
.map-row .row-label { font-family: var(--mono); font-size: 11px; color: var(--text-soft); width: 44px; flex: none; text-align: right; }
.map-cells { display: grid; grid-template-columns: repeat(25, minmax(0, 1fr)); gap: 2px; flex: 1; min-width: 0; }
.cell {
  height: 24px; border-radius: 4px;
  display: flex; align-items: center; justify-content: center;
  font-family: var(--mono); font-size: 10.5px; font-weight: 600;
  border: 1px solid transparent; cursor: default; user-select: none;
}
.cell.free { background: #f4f4f5; color: var(--text-soft); border-color: var(--border); }
.cell.used { color: #fff; cursor: pointer; }
.cell.used.r0 { background: var(--repo-0); }
.cell.used.r1 { background: var(--repo-1); }
.cell.used.r2 { background: var(--repo-2); }
.cell.collision { background: var(--danger); box-shadow: 0 0 0 2px var(--bg-card), 0 0 0 4px var(--danger); cursor: pointer; }
.cell.used:hover, .cell.collision:hover { outline: 2px solid var(--text); outline-offset: 1px; }

#tooltip {
  position: fixed; z-index: 100; pointer-events: none;
  background: #18181b; color: #fafafa; border-radius: 6px;
  padding: 8px 11px; font-size: 12.5px; line-height: 1.5;
  max-width: 340px; box-shadow: 0 6px 20px rgba(0,0,0,.22); display: none;
}
#tooltip .tt-title { font-family: var(--mono); font-weight: 700; margin-bottom: 3px; }
#tooltip .tt-row { color: #d4d4d8; }
#tooltip .tt-file { color: #a1a1aa; font-family: var(--mono); font-size: 11.5px; }

.toggle-empty {
  font-size: 13px; background: none; border: 1px solid var(--border);
  border-radius: 6px; padding: 6px 12px; cursor: pointer;
  color: var(--text-muted); font-family: inherit; margin: 4px 0 14px;
}
.toggle-empty:hover { border-color: var(--accent); color: var(--accent); }

/* ID-uri libere */
.free-table td.ids { font-family: var(--mono); font-size: 12.5px; color: var(--text-muted); line-height: 1.9; }
.free-table .next-free { font-family: var(--mono); font-weight: 700; color: var(--success); }
.chip {
  display: inline-block; background: var(--success-bg); color: #15803d;
  border-radius: 4px; padding: 1px 6px; margin: 0 3px 3px 0; font-size: 12px;
}

/* Filtre + tabel obiecte */
.filters { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin: 16px 0 12px; }
.filters input[type=search], .filters select {
  font-family: inherit; font-size: 14px; padding: 8px 11px;
  border: 1px solid var(--border); border-radius: 7px;
  background: var(--bg-card); color: var(--text); min-width: 150px;
}
.filters input[type=search] { flex: 1; min-width: 220px; }
.filters input[type=search]:focus, .filters select:focus { outline: 2px solid var(--accent); outline-offset: -1px; border-color: var(--accent); }
.filters .count { font-size: 13px; color: var(--text-muted); margin-left: auto; }
.filters button {
  font-family: inherit; font-size: 13px; padding: 8px 12px;
  border: 1px solid var(--border); border-radius: 7px;
  background: var(--bg-card); color: var(--text-muted); cursor: pointer;
}
.filters button:hover { border-color: var(--accent); color: var(--accent); }

.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; margin: 8px 0 16px; font-size: 14px; background: var(--bg-card); border-radius: 8px; overflow: hidden; border: 1px solid var(--border); }
th, td { text-align: left; padding: 9px 13px; border-bottom: 1px solid var(--border-soft); vertical-align: top; }
th { background: #f9fafb; font-weight: 600; font-size: 12.5px; color: var(--text-muted); letter-spacing: 0.02em; text-transform: uppercase; white-space: nowrap; }
tr:last-child td { border-bottom: none; }
tbody tr:hover td { background: #fafbfc; }
td.id { font-family: var(--mono); font-weight: 600; white-space: nowrap; }
td.type { font-family: var(--mono); font-size: 12.5px; color: var(--text-muted); white-space: nowrap; }
td.file { font-family: var(--mono); font-size: 12px; color: var(--text-soft); word-break: break-all; }
.repo-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; vertical-align: middle; flex: none; }
.repo-dot.r0 { background: var(--repo-0); }
.repo-dot.r1 { background: var(--repo-1); }
.repo-dot.r2 { background: var(--repo-2); }
td.repo { white-space: nowrap; font-size: 13px; }
.empty-row td { text-align: center; color: var(--text-soft); padding: 26px; font-style: italic; }

.badge {
  display: inline-block; font-size: 11.5px; font-weight: 600;
  letter-spacing: 0.03em; text-transform: uppercase;
  padding: 3px 9px; border-radius: 4px; background: var(--accent-soft); color: var(--accent);
}
.badge.conf-high { background: var(--success-bg); color: var(--success); }
.badge.conf-inferred { background: var(--warning-bg); color: var(--warning); }

footer {
  max-width: var(--max-w); margin: 40px auto 0; padding: 24px;
  border-top: 1px solid var(--border); font-size: 13px; color: var(--text-soft);
}
footer code { font-size: 12.5px; }

@media (max-width: 760px) {
  main { padding: 20px 16px 48px; }
  h1 { font-size: 24px; }
  h2 { font-size: 19px; }
  .topbar { padding: 0 14px; gap: 10px; }
  .topbar .version { display: none; }
  /* Sub 760px, 25 de coloane devin ilizibile: se trece la 10 pe rand, iar
     eticheta de rand se ascunde pentru ca nu mai corespunde randului vizual. */
  .map-cells { grid-template-columns: repeat(10, minmax(0, 1fr)); }
  .map-row .row-label { display: none; }
  .map-row { align-items: flex-start; }
  .filters .count { margin-left: 0; }
}

@media print {
  .topbar { position: static; background: #fff; color: #000; border-bottom: 2px solid #000; }
  .topbar .version { color: #000; }
  body { background: #fff; }
  main { max-width: 100%; padding: 0; }
  .filters, .toggle-empty, #tooltip { display: none !important; }
  table, .map-type, .callout { break-inside: avoid; }
}
</style>
</head>
<body>

<div class="topbar">
  <span class="brand">BAT LSC PTE<span class="accent">Registru ID-uri obiecte</span></span>
  <span class="breadcrumb">docs / object-registry</span>
  <span class="version" id="generated-badge"></span>
</div>

<main>
  <h1>Registru ID-uri obiecte AL</h1>
  <p class="lead">
    Ce ID-uri sunt deja folosite în cele două repo-uri BAT și ce mai e liber din range,
    pe fiecare tip de obiect. Pagina e <strong>generată</strong> — nu se editează de mână.
  </p>

  <div class="stats" id="stats"></div>

  <div id="alerts"></div>

  <h2>Harta range-ului</h2>
  <p>
    Fiecare bloc e un tip de obiect. Fiecare celulă e un ID din range; eticheta e ultimele
    două cifre. Treci cu mouse-ul peste o celulă ocupată ca să vezi ce e acolo, sau
    dă click ca să filtrezi tabelul de mai jos pe acel ID.
  </p>
  <div class="legend" id="legend"></div>
  <div id="map"></div>
  <button class="toggle-empty" id="toggle-empty" type="button"></button>

  <h2>ID-uri libere pe tip</h2>
  <p>
    Calculate pe reuniunea repo-urilor scanate, nu pe fiecare separat —
    vezi nota despre unicitate de mai jos.
  </p>
  <div class="table-wrap">
    <table class="free-table">
      <thead>
        <tr><th>Tip obiect</th><th>Următorul liber</th><th>Libere</th><th>ID-uri libere</th></tr>
      </thead>
      <tbody id="free-body"></tbody>
    </table>
  </div>

  <h2>Toate obiectele</h2>
  <div class="filters">
    <input type="search" id="q" placeholder="Caută după nume, ID, fișier..." aria-label="Caută în tabelul de obiecte">
    <select id="f-type" aria-label="Filtrează după tip de obiect"></select>
    <select id="f-repo" aria-label="Filtrează după repo"></select>
    <button type="button" id="reset">Resetează</button>
    <span class="count" id="count"></span>
  </div>
  <div class="table-wrap">
    <table>
      <thead>
        <tr><th>Repo</th><th>Tip</th><th>ID</th><th>Nume</th><th>Fișier</th></tr>
      </thead>
      <tbody id="obj-body"></tbody>
    </table>
  </div>

  <h2>Regula de unicitate a ID-urilor</h2>

  <p>
    <span class="badge conf-high">Încredere ridicată</span>
    <strong>Unicitatea e per TIP de obiect, nu globală.</strong>
    Același număr poate fi refolosit o dată pentru fiecare tip de obiect AL.
  </p>

  <p>
    Dovada directă vine din <code>bc-lscentral-bat-starter/app</code> (app <code>BAT LSC PTE</code>,
    versiune 1.0.209.0, target Cloud, publicat și funcțional pe LSRetail2): ID-ul 50100 e folosit
    simultan de cinci obiecte de tipuri diferite — <code>table 50100</code>, <code>tableextension 50100</code>,
    <code>pageextension 50100</code>, <code>report 50100</code>, <code>permissionset 50100</code>.
    Cazul cel mai tare: <code>tableextension 50100</code> și <code>pageextension 50100</code> sunt
    în <em>același fișier</em> (<code>MixMatchExtension.al</code>) și compilează. Dacă regula ar fi
    globală, <code>alc.exe</code> ar refuza build-ul. Tiparul se repetă la 50101, 50107, 50125 și 50128.
    Harta de mai sus arată aceleași suprapuneri, recalculate la fiecare rulare.
  </p>

  <div class="callout warning">
    <strong>Ce e inferat, nu dovedit</strong>
    <p>
      <span class="badge conf-inferred">Inferență</span>
      Că <code>page 50100</code> și <code>pageextension 50100</code> pot coexista este dedus prin
      simetrie cu perechea table/tableextension. În repo-urile scanate nu există <code>page 50100</code>,
      deci nu avem dovadă directă în date. Încredere ridicată, dar marcat explicit ca inferență.
      Același statut pentru perechile report/reportextension, enum/enumextension,
      permissionset/permissionsetextension.
    </p>
    <p>
      Regula nu a fost validată rulând un build dedicat și nu s-a interogat tenantul LSRetail2.
      Concluzia se sprijină pe faptul că app-ul soră e publicat și funcționează, coroborat cu
      structura codului. Dacă vrei certitudine înainte de o alocare riscantă, cel mai ieftin test
      e un <code>./build.ps1</code> cu obiectul nou adăugat.
    </p>
  </div>

  <div class="callout danger">
    <strong>Domeniul de unicitate e TENANT-ul, nu proiectul</strong>
    <p>
      Numărul trebuie să fie liber pentru acel tip în <em>toate</em> extensiile instalate pe tenant,
      plus base app plus LS Central. De aceea range-ul din <code>app.json</code> e o rezervare la
      nivel de tenant, nu doar la nivel de proiect, și de aceea pagina calculează liberul pe
      reuniunea repo-urilor scanate, nu pe fiecare separat.
    </p>
    <p>
      <strong>Ce nu vede pagina:</strong> obiectele altor extensii instalate pe LSRetail2. Scriptul
      nu interoghează tenantul. Range-ul 50100-50149 e rezervat prin convenție PTE-urilor BAT, dar
      asta nu e verificat automat aici. Pentru ce e instalat efectiv:
      <code>pwsh ./tools/Get-LSRetail2Extensions.ps1</code>.
    </p>
  </div>

  <div id="overlap-note"></div>

  <h2>Cum se regenerează</h2>
  <p>Din rădăcina repo-ului <code>bc-lscentral-bat-starter - template</code>:</p>
  <pre><code id="regen-cmd"></code></pre>
  <p>
    Scanate la ultima rulare: <span id="scanned-paths"></span>.
    Datele brute stau lângă pagină, în <code>registry.json</code>.
  </p>
</main>

<footer>
  Generat automat de <code>tools/Get-ObjectIdRegistry.ps1</code> la
  <span id="generated-footer"></span>. Nu edita <code>index.html</code> de mână —
  următoarea regenerare îl suprascrie.
</footer>

<div id="tooltip" role="tooltip"></div>

<script type="application/json" id="registry-data">__REGISTRY_JSON__</script>
<script>
(function () {
  'use strict';

  var DATA = JSON.parse(document.getElementById('registry-data').textContent);
  var REPO_KEYS = {};
  DATA.repos.forEach(function (r, i) { REPO_KEYS[r.name] = i; });

  function esc(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function repoClass(name) {
    var i = REPO_KEYS[name];
    return 'r' + (i === undefined ? 0 : i % 3);
  }
  function el(id) { return document.getElementById(id); }

  /* ---------- antet ---------- */
  el('generated-badge').textContent = DATA.generatedAt;
  el('generated-footer').textContent = DATA.generatedAt;
  el('regen-cmd').textContent = DATA.command;
  el('scanned-paths').innerHTML = DATA.scannedPaths.map(function (p) {
    return '<code>' + esc(p) + '</code>';
  }).join(' · ');

  /* ---------- tile-uri ---------- */
  var totalFree = DATA.byType.reduce(function (a, t) { return a + t.freeCount; }, 0);
  var tiles = [
    { v: DATA.stats.objectCount, l: 'obiecte declarate', c: '' },
    { v: DATA.stats.repoCount, l: 'repo-uri scanate', c: '' },
    { v: DATA.rangeMin + '-' + DATA.rangeMax, l: 'range declarat', c: 'range' },
    { v: totalFree, l: 'sloturi libere (toate tipurile)', c: 'ok' },
    { v: DATA.stats.collisionCount, l: 'coliziuni', c: DATA.stats.collisionCount ? 'bad' : 'ok' },
    { v: DATA.stats.outOfRangeCount, l: 'în afara range-ului', c: DATA.stats.outOfRangeCount ? 'bad' : 'ok' }
  ];
  el('stats').innerHTML = tiles.map(function (t) {
    return '<div class="stat ' + t.c + '"><div class="value">' + esc(t.v) + '</div>' +
           '<div class="label">' + esc(t.l) + '</div></div>';
  }).join('');

  /* ---------- alerte ---------- */
  var alerts = '';
  if (DATA.collisions.length) {
    alerts += '<div class="callout danger"><strong>Coliziuni de ID — ' + DATA.collisions.length + '</strong>';
    alerts += '<p>Același tip de obiect cu același ID declarat de mai multe ori. ' +
              'În același repo înseamnă că nu compilează; între repo-uri înseamnă că cele două ' +
              'app-uri nu pot sta simultan pe același tenant.</p><ul>';
    DATA.collisions.forEach(function (c) {
      alerts += '<li><code>' + esc(c.type) + ' ' + c.id + '</code> — ' + esc(c.scope) +
                ' (' + esc(c.severity) + '):<ul>';
      c.occurrences.forEach(function (o) {
        alerts += '<li>' + esc(o.repo) + ' — <strong>' + esc(o.name) + '</strong> ' +
                  '<code>' + esc(o.file) + ':' + o.line + '</code></li>';
      });
      alerts += '</ul></li>';
    });
    alerts += '</ul></div>';
  } else {
    alerts += '<div class="callout success"><strong>Fără coliziuni</strong>' +
              '<p>Niciun tip de obiect nu are același ID declarat de două ori în folderele scanate.</p></div>';
  }
  if (DATA.outOfRange.length) {
    alerts += '<div class="callout warning"><strong>Obiecte în afara range-ului declarat — ' +
              DATA.outOfRange.length + '</strong><ul>';
    DATA.outOfRange.forEach(function (o) {
      alerts += '<li><code>' + esc(o.type) + ' ' + o.id + '</code> <strong>' + esc(o.name) + '</strong> ' +
                '(' + esc(o.repo) + ', range declarat ' + esc(o.declaredRanges.join(', ')) + ') — ' +
                '<code>' + esc(o.file) + ':' + o.line + '</code></li>';
    });
    alerts += '</ul></div>';
  }
  el('alerts').innerHTML = alerts;

  /* ---------- nota despre range-uri suprapuse ---------- */
  if (DATA.rangeOverlaps.length) {
    var oh = '<div class="callout warning"><strong>Două app-uri diferite declară același range</strong><ul>';
    DATA.rangeOverlaps.forEach(function (o) {
      oh += '<li>' + esc(o.appA) + ' &harr; ' + esc(o.appB) +
            ' se suprapun pe <code>' + o.from + '-' + o.to + '</code></li>';
    });
    oh += '</ul><p>Nu e o eroare acum, dar dacă ambele ajung instalate simultan pe LSRetail2, ' +
          'orice obiect viitor cu același tip și același ID în ambele va da conflict la instalare. ' +
          'De asta pagina calculează liberul pe reuniunea repo-urilor, nu pe fiecare separat.</p></div>';
    el('overlap-note').innerHTML = oh;
  }

  if (DATA.duplicateManifests.length) {
    var dh = '<div class="callout info"><strong>Același app id în mai multe app.json</strong><ul>';
    DATA.duplicateManifests.forEach(function (d) {
      dh += '<li><strong>' + esc(d.appName) + '</strong> (<code>' + esc(d.appId) + '</code>):<ul>' +
            d.manifests.map(function (m) { return '<li><code>' + esc(m) + '</code></li>'; }).join('') +
            '</ul></li>';
    });
    dh += '</ul><p>Manifeste duplicate. Nu e o eroare de compilare, dar nu se mai vede din care ' +
          'citește build-ul; dacă cele două se despart în timp, range-ul declarat devine ambiguu. ' +
          'Merită clarificat care e cel efectiv folosit.</p></div>';
    el('overlap-note').insertAdjacentHTML('beforeend', dh);
  }

  /* ---------- index: tip|id -> obiecte ---------- */
  var byKey = {};
  DATA.objects.forEach(function (o) {
    var k = o.type + '|' + o.id;
    (byKey[k] = byKey[k] || []).push(o);
  });

  /* ---------- legenda ---------- */
  var legend = DATA.repos.map(function (r, i) {
    return '<span class="item"><span class="swatch" style="background:var(--repo-' + (i % 3) + ')"></span>' +
           esc(r.name) + '</span>';
  }).join('');
  legend += '<span class="item"><span class="swatch" style="background:#f4f4f5;border-color:var(--border)"></span>liber</span>';
  legend += '<span class="item"><span class="swatch" style="background:var(--danger)"></span>coliziune</span>';
  el('legend').innerHTML = legend;

  /* ---------- harta ---------- */
  var ROW = 25;
  function buildMapType(t) {
    var head = '<div class="map-head"><span class="name">' + esc(t.type) + '</span>' +
               '<span class="counts">' + t.usedCount + ' ocupate · ' + t.freeCount + ' libere</span>' +
               (t.nextFree !== null ? '<span class="next">următorul liber: ' + t.nextFree + '</span>' : '') +
               '</div>';
    var rows = '';
    for (var start = 0; start < DATA.rangeIds.length; start += ROW) {
      var slice = DATA.rangeIds.slice(start, start + ROW);
      var cells = slice.map(function (id) {
        var objs = byKey[t.type + '|' + id];
        var label = String(id).slice(-2);
        if (!objs) {
          return '<div class="cell free" aria-label="' + t.type + ' ' + id + ' liber">' + label + '</div>';
        }
        var cls = objs.length > 1 ? 'cell used collision' : 'cell used ' + repoClass(objs[0].repo);
        return '<div class="' + cls + '" data-type="' + esc(t.type) + '" data-id="' + id +
               '" tabindex="0" role="button" aria-label="' + esc(t.type) + ' ' + id + ': ' +
               esc(objs.map(function (o) { return o.name; }).join(', ')) + '">' + label + '</div>';
      }).join('');
      rows += '<div class="map-row"><span class="row-label">' + slice[0] + '</span>' +
              '<div class="map-cells">' + cells + '</div></div>';
    }
    return '<div class="map-type">' + head + rows + '</div>';
  }

  var usedTypes = DATA.byType.filter(function (t) { return t.usedCount > 0; });
  var emptyTypes = DATA.byType.filter(function (t) { return t.usedCount === 0; });
  el('map').innerHTML = usedTypes.map(buildMapType).join('') +
    '<div id="empty-types" style="display:none">' + emptyTypes.map(buildMapType).join('') + '</div>';

  var toggle = el('toggle-empty');
  if (emptyTypes.length === 0) {
    toggle.style.display = 'none';
  } else {
    var shown = false;
    function syncToggle() {
      el('empty-types').style.display = shown ? 'block' : 'none';
      toggle.textContent = (shown ? 'Ascunde' : 'Arată') + ' tipurile complet libere (' + emptyTypes.length + ')';
    }
    toggle.addEventListener('click', function () { shown = !shown; syncToggle(); });
    syncToggle();
  }

  /* ---------- tooltip ---------- */
  var tip = el('tooltip');
  function showTip(cell, x, y) {
    var objs = byKey[cell.dataset.type + '|' + cell.dataset.id];
    if (!objs) { return; }
    tip.innerHTML = objs.map(function (o) {
      return '<div class="tt-title">' + esc(o.type) + ' ' + o.id + '</div>' +
             '<div class="tt-row">' + esc(o.name) + (o.extends ? ' extends ' + esc(o.extends) : '') + '</div>' +
             '<div class="tt-row">' + esc(o.repo) + '</div>' +
             '<div class="tt-file">' + esc(o.relativeFile) + ':' + o.line + '</div>';
    }).join('<hr style="border:0;border-top:1px solid #3f3f46;margin:6px 0">');
    tip.style.display = 'block';
    var r = tip.getBoundingClientRect();
    var left = Math.min(x + 14, window.innerWidth - r.width - 10);
    var top = y + 18 + r.height > window.innerHeight ? y - r.height - 12 : y + 18;
    tip.style.left = Math.max(6, left) + 'px';
    tip.style.top = Math.max(6, top) + 'px';
  }
  function hideTip() { tip.style.display = 'none'; }

  el('map').addEventListener('mousemove', function (e) {
    var cell = e.target.closest('.cell.used, .cell.collision');
    if (cell) { showTip(cell, e.clientX, e.clientY); } else { hideTip(); }
  });
  el('map').addEventListener('mouseleave', hideTip);
  el('map').addEventListener('focusin', function (e) {
    var cell = e.target.closest('.cell.used, .cell.collision');
    if (cell) {
      var r = cell.getBoundingClientRect();
      showTip(cell, r.left, r.bottom - 12);
    }
  });
  el('map').addEventListener('focusout', hideTip);

  /* ---------- click pe celula: filtreaza tabelul ---------- */
  el('map').addEventListener('click', function (e) {
    var cell = e.target.closest('.cell.used, .cell.collision');
    if (!cell) { return; }
    el('f-type').value = cell.dataset.type;
    el('q').value = cell.dataset.id;
    render();
    document.querySelector('#obj-body').scrollIntoView({ behavior: 'smooth', block: 'center' });
  });

  /* ---------- ID-uri libere ----------
     ID-urile consecutive se strang intr-un singur chip (50104-50107): o lista
     de 50 de numere identice pentru fiecare tip liber nu se citeste. */
  function compactRanges(ids) {
    var out = [], i = 0;
    while (i < ids.length) {
      var start = ids[i], end = start;
      while (i + 1 < ids.length && ids[i + 1] === ids[i] + 1) { i++; end = ids[i]; }
      out.push(start === end ? String(start) : start + '–' + end);
      i++;
    }
    return out;
  }

  el('free-body').innerHTML = DATA.byType.map(function (t) {
    var ids = t.freeIds.length
      ? compactRanges(t.freeIds).map(function (r) { return '<span class="chip">' + r + '</span>'; }).join('')
      : '<em>niciunul</em>';
    return '<tr><td class="type">' + esc(t.type) + '</td>' +
           '<td class="next-free">' + (t.nextFree === null ? '—' : t.nextFree) + '</td>' +
           '<td>' + t.freeCount + ' / ' + DATA.rangeIds.length + '</td>' +
           '<td class="ids">' + ids + '</td></tr>';
  }).join('');

  /* ---------- filtre + tabel ---------- */
  var typeSel = el('f-type'), repoSel = el('f-repo'), q = el('q');
  typeSel.innerHTML = '<option value="">Toate tipurile</option>' +
    DATA.byType.filter(function (t) { return t.usedCount > 0; })
      .map(function (t) { return '<option value="' + esc(t.type) + '">' + esc(t.type) + ' (' + t.usedCount + ')</option>'; })
      .join('');
  repoSel.innerHTML = '<option value="">Toate repo-urile</option>' +
    DATA.repos.map(function (r) { return '<option value="' + esc(r.name) + '">' + esc(r.name) + '</option>'; }).join('');

  function render() {
    var term = q.value.trim().toLowerCase();
    var ft = typeSel.value, fr = repoSel.value;
    var rows = DATA.objects.filter(function (o) {
      if (ft && o.type !== ft) { return false; }
      if (fr && o.repo !== fr) { return false; }
      if (!term) { return true; }
      return (o.name + ' ' + o.id + ' ' + o.type + ' ' + o.relativeFile + ' ' + (o.extends || ''))
        .toLowerCase().indexOf(term) !== -1;
    });

    el('count').textContent = rows.length + ' din ' + DATA.objects.length + ' obiecte';
    el('obj-body').innerHTML = rows.length
      ? rows.map(function (o) {
          return '<tr><td class="repo"><span class="repo-dot ' + repoClass(o.repo) + '"></span>' + esc(o.repo) + '</td>' +
                 '<td class="type">' + esc(o.type) + '</td>' +
                 '<td class="id">' + o.id + '</td>' +
                 '<td>' + esc(o.name) + (o.extends ? ' <span style="color:var(--text-soft)">extends ' + esc(o.extends) + '</span>' : '') + '</td>' +
                 '<td class="file">' + esc(o.relativeFile) + ':' + o.line + '</td></tr>';
        }).join('')
      : '<tr class="empty-row"><td colspan="5">Niciun obiect nu se potrivește cu filtrele.</td></tr>';
  }

  q.addEventListener('input', render);
  typeSel.addEventListener('change', render);
  repoSel.addEventListener('change', render);
  el('reset').addEventListener('click', function () {
    q.value = ''; typeSel.value = ''; repoSel.value = ''; render();
  });

  render();
})();
</script>
</body>
</html>
'@

$html = $template.Replace('__REGISTRY_JSON__', (ConvertTo-JsonSafeForHtml -InputObject $registry))
$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8

Write-Host "Obiecte gasite : $($registry.stats.objectCount) in $($registry.stats.fileCount) fisiere .al din $($registry.stats.repoCount) repo-uri"
Write-Host "Coliziuni      : $($registry.stats.collisionCount)   In afara range-ului: $($registry.stats.outOfRangeCount)"
Write-Host "Date           : $jsonPath"
Write-Host "Pagina         : $htmlPath"
