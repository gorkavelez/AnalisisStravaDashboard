<#
.SYNOPSIS
  Calcula parciales por km (ritmo, FC media, zona) para las N carreras más
  recientes y genera splits.json, listo para embeber en index.html.

.DESCRIPTION
  A diferencia de fetch_strava_activities.ps1 (que usa el listado general de
  actividades), este script necesita una llamada a la API por actividad
  (GET /activities/{id}/streams), así que solo se aplica a un número acotado
  de carreras recientes para no chocar con el límite de 100 peticiones/15min
  de Strava.

  Para cada carrera:
    1. Trae los streams de distancia, frecuencia cardiaca y tiempo.
    2. Agrupa las muestras en tramos de ~1000 m (el último tramo puede ser
       parcial; se descarta si mide menos de 150 m).
    3. Calcula el ritmo y la FC media de cada tramo.
    4. Asigna una zona 1-5 según el % de FC máxima de referencia
       (Z1 <60%, Z2 60-70%, Z3 70-80%, Z4 80-90%, Z5 ≥90%).

  Requiere el mismo tipo de credenciales que fetch_strava_activities.ps1.

.PARAMETER ClientId
  Client ID de tu app de Strava.

.PARAMETER ClientSecret
  Client Secret de tu app de Strava.

.PARAMETER RefreshToken
  Refresh token de una autorización previa (ver fetch_strava_activities.ps1).

.PARAMETER MaxHr
  Frecuencia cardiaca máxima de referencia para las zonas. Por defecto 192
  (la máxima histórica registrada hasta ahora). Súbela si superas ese valor.

.PARAMETER Count
  Cuántas carreras recientes procesar. Por defecto 30.

.PARAMETER ActivitiesJson
  Ruta a activities.json (para sacar de ahí los IDs de las carreras más
  recientes). Por defecto, el que hay junto a este script.

.EXAMPLE
  ./fetch_strava_splits.ps1 -ClientId 12345 -ClientSecret xxxx -RefreshToken yyyy -Count 30
#>

param(
  [Parameter(Mandatory=$true)][string]$ClientId,
  [Parameter(Mandatory=$true)][string]$ClientSecret,
  [Parameter(Mandatory=$true)][string]$RefreshToken,
  [int]$MaxHr = 192,
  [int]$Count = 30,
  [string]$ActivitiesJson = (Join-Path $PSScriptRoot "activities.json")
)

$ErrorActionPreference = "Stop"

# --- 1. Access token ---
$tokenResp = Invoke-RestMethod -Method Post -Uri "https://www.strava.com/oauth/token" -Body @{
  client_id     = $ClientId
  client_secret = $ClientSecret
  refresh_token = $RefreshToken
  grant_type    = "refresh_token"
}
$accessToken = $tokenResp.access_token
$headers = @{ Authorization = "Bearer $accessToken" }

# --- 2. IDs de las N carreras más recientes ---
$activities = Get-Content $ActivitiesJson -Raw | ConvertFrom-Json
$recentRuns = $activities | Where-Object { $_.t -eq "Carrera" } | Sort-Object d | Select-Object -Last $Count
Write-Host "Procesando $($recentRuns.Count) carreras recientes..."

function Get-Zone($hr, $maxHr) {
  $pct = $hr / $maxHr
  if ($pct -lt 0.60) { return 1 }
  if ($pct -lt 0.70) { return 2 }
  if ($pct -lt 0.80) { return 3 }
  if ($pct -lt 0.90) { return 4 }
  return 5
}

# --- 3. Streams + cálculo de parciales por actividad ---
$result = @{}
$i = 0
foreach ($act in $recentRuns) {
  $i++
  Write-Host "[$i/$($recentRuns.Count)] id=$($act.id) - $($act.n)"
  try {
    $s = Invoke-RestMethod -Uri "https://www.strava.com/api/v3/activities/$($act.id)/streams?keys=distance,heartrate,time&key_by_type=true" -Headers $headers
  } catch {
    Write-Host "  aviso: sin streams disponibles, se omite"
    continue
  }
  if (-not $s.distance -or -not $s.heartrate -or -not $s.time) { continue }

  $dist = $s.distance.data
  $hr = $s.heartrate.data
  $time = $s.time.data
  $n = $dist.Count
  if ($n -eq 0) { continue }

  $splits = @()
  $curKm = 1
  $bucketHr = New-Object System.Collections.Generic.List[double]
  $lastSplitTime = 0
  $lastSplitDist = 0.0

  for ($j=0; $j -lt $n; $j++) {
    $bucketHr.Add([double]$hr[$j])
    if ($dist[$j] -ge ($curKm*1000) -or $j -eq $n-1) {
      $segDist = $dist[$j] - $lastSplitDist
      if ($segDist -lt 150 -and $splits.Count -gt 0) { break }
      $segTime = $time[$j] - $lastSplitTime
      $avgHr = ($bucketHr | Measure-Object -Average).Average
      $paceSec = if ($segDist -gt 0) { [math]::Round($segTime * 1000 / $segDist) } else { 0 }
      $splits += , @($curKm, [math]::Round($avgHr), (Get-Zone $avgHr $MaxHr), $paceSec, [math]::Round($segDist))
      $lastSplitTime = $time[$j]
      $lastSplitDist = $dist[$j]
      $bucketHr.Clear()
      $curKm++
      if ($dist[$j] -lt ($curKm*1000) -and $j -eq $n-1) { break }
    }
  }
  if ($splits.Count -gt 0) { $result["$($act.id)"] = $splits }
}

Write-Host "Actividades con splits calculados: $($result.Count)"

$outPath = Join-Path $PSScriptRoot "splits.json"
$json = $result | ConvertTo-Json -Depth 4 -Compress
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)
Write-Host "Escrito $outPath"

# --- 4. Reinyectar en index.html ---
$htmlPath = Join-Path $PSScriptRoot "index.html"
if (Test-Path $htmlPath) {
  $bytes = [System.IO.File]::ReadAllBytes($outPath)
  $b64 = [Convert]::ToBase64String($bytes)
  $html = Get-Content -Path $htmlPath -Raw -Encoding UTF8
  $pattern = '(?<=<script id="splits-data-b64" type="text/plain">)[^<]+(?=</script>)'
  if ($html -match $pattern) {
    $newHtml = [regex]::Replace($html, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $b64 })
    [System.IO.File]::WriteAllText($htmlPath, $newHtml, $utf8NoBom)
    Write-Host "Actualizado index.html"
  } else {
    Write-Host "Aviso: marcador de datos de splits no encontrado en index.html"
  }
}
