<#
.SYNOPSIS
    Generează o colecție Postman și un environment din cele două spec-uri OpenAPI publice Innoship.

.DESCRIPTION
    Innoship publică două spec-uri separate, pe două host-uri:
      - https://api.innoship.com/swagger/v1/swagger.json    — "Innoship API", operațiile de scriere
      - https://query.innoship.com/swagger/v1/swagger.json  — "Innoship static API", citirile migrate

    Împărțirea pe host vine din spec-ul în care apare fiecare operație, nu dintr-o presupunere.
    Anunțul de migrare din 20 iulie 2026 mută citirile pe query.innoship.com; ambele host-uri
    merg în paralel până la 30 iunie 2027, când cele vechi încep să dea eroare.

    Innoship NU are mediu de sandbox. Toate cererile lovesc producția, iar POST /api/Order
    generează un AWB real la curier, cu cost real. De aceea operațiile sunt împărțite în două
    foldere, iar cel periculos are prefixul "!" ca să fie vizibil în Postman.

    Cheia de API NU se scrie niciodată în fișierele generate. Environment-ul conține variabila
    goală, marcată ca secret; o completezi tu în Postman.

.EXAMPLE
    pwsh ./tools/New-InnoshipPostmanCollection.ps1

.EXAMPLE
    pwsh ./tools/New-InnoshipPostmanCollection.ps1 -ApiSpecPath .\api.json -QuerySpecPath .\query.json
#>
[CmdletBinding()]
param(
    [string] $ApiSpecUrl   = 'https://api.innoship.com/swagger/v1/swagger.json',
    [string] $QuerySpecUrl = 'https://query.innoship.com/swagger/v1/swagger.json',
    [string] $ApiSpecPath,
    [string] $QuerySpecPath,
    [string] $OutFolder = (Join-Path (Join-Path $PSScriptRoot '..') 'docs\innoship')
)

$ErrorActionPreference = 'Stop'

# Operațiile non-GET care nu produc efecte la curier. Orice altceva non-GET e considerat cu efecte.
$SafeOperations = @(
    'POST /api/Order/simulate'
    'POST /api/Price'
    'POST /api/ClientLocation/Validate'
    'POST /api/ClientLocation/Summary'
)

function Get-Spec {
    param([string] $Path, [string] $Url, [string] $Label)
    if ($Path) {
        Write-Host "$Label : spec local $Path"
        return Get-Content $Path -Raw | ConvertFrom-Json
    }
    Write-Host "$Label : descarc $Url"
    return Invoke-RestMethod -Uri $Url -TimeoutSec 120
}

function Resolve-Schema {
    <# Rezolvă $ref din $script:schemas și produce o valoare exemplu.
       $Seen oprește recursivitatea pe scheme ciclice. #>
    param($Schema, [System.Collections.Generic.HashSet[string]] $Seen, [int] $Depth = 0)

    if (-not $Schema -or $Depth -gt 6) { return $null }

    $ref = $Schema.'$ref'
    if ($ref) {
        $name = $ref -replace '^#/components/schemas/', ''
        if (-not $Seen.Add($name)) { return $null }   # ciclu — oprim aici
        $value = Resolve-Schema -Schema $script:schemas.$name -Seen $Seen -Depth ($Depth + 1)
        [void] $Seen.Remove($name)
        return $value
    }

    if ($null -ne $Schema.example) { return $Schema.example }
    if ($null -ne $Schema.default) { return $Schema.default }
    if ($Schema.enum) { return $Schema.enum[0] }

    $props = $Schema.properties
    switch ($Schema.type) {
        'array'   { return @(Resolve-Schema -Schema $Schema.items -Seen $Seen -Depth ($Depth + 1)) }
        'integer' { return 0 }
        'number'  { return 0 }
        'boolean' { return $false }
        'string'  {
            switch ($Schema.format) {
                'date-time' { return '2026-01-01T00:00:00Z' }
                'date'      { return '2026-01-01' }
                'uuid'      { return '00000000-0000-0000-0000-000000000000' }
                default     { return '' }
            }
        }
    }

    # 'object', sau tip absent dar cu properties
    if ($props) {
        $o = [ordered] @{}
        foreach ($p in $props.PSObject.Properties) {
            $o[$p.Name] = Resolve-Schema -Schema $p.Value -Seen $Seen -Depth ($Depth + 1)
        }
        return $o
    }
    return $null
}

# ---------------------------------------------------------------- citire spec-uri

$sources = @(
    @{ Spec = (Get-Spec $ApiSpecPath   $ApiSpecUrl   'scriere ') ; HostVar = '{{apiBase}}'   ; Origin = 'api'   }
    @{ Spec = (Get-Spec $QuerySpecPath $QuerySpecUrl 'citire  ') ; HostVar = '{{queryBase}}' ; Origin = 'query' }
)

$operations = @()
foreach ($src in $sources) {
    $script:schemas = $src.Spec.components.schemas

    foreach ($pathProp in $src.Spec.paths.PSObject.Properties) {
        $path = $pathProp.Name
        foreach ($methodProp in $pathProp.Value.PSObject.Properties) {
            $method = $methodProp.Name.ToUpperInvariant()
            if ($method -notin 'GET', 'POST', 'PUT', 'PATCH', 'DELETE') { continue }
            $op = $methodProp.Value

            $body = $null
            $jsonContent = $op.requestBody.content.'application/json'
            if ($jsonContent -and $jsonContent.schema) {
                $sample = Resolve-Schema -Schema $jsonContent.schema -Seen ([System.Collections.Generic.HashSet[string]]::new())
                if ($null -ne $sample) { $body = $sample | ConvertTo-Json -Depth 20 }
            }

            # Spec-ul declară api-version obligatoriu în QUERY și opțional în header, deși
            # documentația Innoship și colecția lor oficială îl pun doar în header. Trimitem
            # ambele — e singura variantă care satisface și spec-ul, și practica lor.
            $pathVars = @(); $queryParams = @()
            foreach ($prm in @($op.parameters)) {
                if (-not $prm) { continue }
                if ($prm.in -eq 'path') {
                    $pathVars += [ordered] @{ key = $prm.name; value = ''; description = "$($prm.schema.type)" }
                }
                elseif ($prm.in -eq 'query') {
                    $value    = if ($prm.name -eq 'api-version') { '{{apiVersion}}' } else { '' }
                    $disabled = if ($prm.name -eq 'api-version') { $false } else { -not [bool] $prm.required }
                    $queryParams += [ordered] @{ key = $prm.name; value = $value; disabled = $disabled }
                }
            }

            $operations += [pscustomobject] @{
                Tag         = if ($op.tags) { $op.tags[0] } else { 'Altele' }
                Method      = $method
                Path        = $path
                Origin      = $src.Origin
                Host        = $src.HostVar
                Summary     = if ($op.summary) { $op.summary } elseif ($op.description) { ($op.description -split "`n")[0] } else { $path }
                IsSafe      = ($method -eq 'GET') -or ($SafeOperations -contains "$method $path")
                Body        = $body
                PathVars    = $pathVars
                QueryParams = $queryParams
            }
        }
    }
}

$safeCount = @($operations | Where-Object IsSafe).Count
Write-Host "Operații: $($operations.Count)  — fără efecte: $safeCount, cu efecte: $($operations.Count - $safeCount)"
Write-Host "  pe api.innoship.com  : $(@($operations | Where-Object Origin -eq 'api').Count)"
Write-Host "  pe query.innoship.com: $(@($operations | Where-Object Origin -eq 'query').Count)"

# ---------------------------------------------------------------- construire colecție

function New-RequestItem {
    param($Op)

    $headers = @([ordered] @{ key = 'api-version'; value = '{{apiVersion}}' })
    if ($Op.Body) { $headers += [ordered] @{ key = 'Content-Type'; value = 'application/json' } }

    $postmanPath = $Op.Path -replace '\{([^}]+)\}', ':$1'   # Postman folosește :param, nu {param}

    $url = [ordered] @{
        raw  = "$($Op.Host)$postmanPath"
        host = @($Op.Host)
        path = @($postmanPath.Trim('/') -split '/')
    }
    if ($Op.QueryParams.Count) { $url.query    = @($Op.QueryParams) }
    if ($Op.PathVars.Count)    { $url.variable = @($Op.PathVars) }

    $request = [ordered] @{
        method      = $Op.Method
        header      = @($headers)
        url         = $url
        description = $Op.Summary
    }
    if ($Op.Body) {
        $request.body = [ordered] @{
            mode    = 'raw'
            raw     = $Op.Body
            options = [ordered] @{ raw = [ordered] @{ language = 'json' } }
        }
    }

    [ordered] @{ name = "$($Op.Method) $($Op.Path)"; request = $request; response = @() }
}

function New-Folder {
    param([string] $Name, [string] $Description, $Ops)
    [ordered] @{
        name        = $Name
        description = $Description
        item        = @($Ops | Group-Object Tag | Sort-Object Name | ForEach-Object {
                [ordered] @{
                    name = $_.Name
                    item = @($_.Group | Sort-Object Method, Path | ForEach-Object { New-RequestItem $_ })
                }
            })
    }
}

$collection = [ordered] @{
    info     = [ordered] @{
        _postman_id = [guid]::NewGuid().ToString()
        name        = 'Innoship API'
        description = @"
Generată din spec-urile publice Innoship cu tools/New-InnoshipPostmanCollection.ps1.
Nu edita manual — regenerează.

  scriere: $ApiSpecUrl
  citire : $QuerySpecUrl

ATENȚIE: Innoship nu are mediu de sandbox. Toate cererile lovesc producția.
Folderul "! Cu efecte" conține operații care creează AWB-uri reale, cer ridicare
la curier sau trimit SMS-uri. Costă bani și nu se anulează dintr-un click.
Pentru testare folosește "Fără efecte" — în primul rând POST /api/Order/simulate.
"@
        schema      = 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'
    }
    auth     = [ordered] @{
        type   = 'apikey'
        apikey = @(
            [ordered] @{ key = 'key';   value = 'X-Api-Key';          type = 'string' }
            [ordered] @{ key = 'value'; value = '{{innoshipApiKey}}'; type = 'string' }
            [ordered] @{ key = 'in';    value = 'header';             type = 'string' }
        )
    }
    variable = @(
        [ordered] @{ key = 'apiBase';    value = 'https://api.innoship.com';   type = 'string' }
        [ordered] @{ key = 'queryBase';  value = 'https://query.innoship.com'; type = 'string' }
        [ordered] @{ key = 'apiVersion'; value = '1.0';                        type = 'string' }
    )
    item     = @(
        New-Folder 'Fără efecte' 'GET-uri plus simulate/price/validate/summary. Nu creează nimic la curier.' ($operations | Where-Object IsSafe)
        New-Folder '! Cu efecte' 'Creează AWB, cere ridicare, trimite SMS, modifică date. PRODUCȚIE.'        ($operations | Where-Object { -not $_.IsSafe })
    )
}

$environment = [ordered] @{
    id                      = [guid]::NewGuid().ToString()
    name                    = 'Innoship — producție'
    values                  = @(
        [ordered] @{ key = 'innoshipApiKey'; value = ''; type = 'secret';  enabled = $true }
        [ordered] @{ key = 'apiBase';    value = 'https://api.innoship.com';   type = 'default'; enabled = $true }
        [ordered] @{ key = 'queryBase';  value = 'https://query.innoship.com'; type = 'default'; enabled = $true }
        [ordered] @{ key = 'apiVersion'; value = '1.0';                        type = 'default'; enabled = $true }
    )
    _postman_variable_scope = 'environment'
}

New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
$collectionPath  = Join-Path $OutFolder 'Innoship.postman_collection.json'
$environmentPath = Join-Path $OutFolder 'Innoship.postman_environment.json'

$collection  | ConvertTo-Json -Depth 40 | Set-Content $collectionPath  -Encoding utf8
$environment | ConvertTo-Json -Depth 10 | Set-Content $environmentPath -Encoding utf8

Write-Host "Colecție   : $collectionPath"
Write-Host "Environment: $environmentPath  (cheia rămâne goală — o completezi în Postman)"
