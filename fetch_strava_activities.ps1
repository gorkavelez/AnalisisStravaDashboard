<#
.SYNOPSIS
  Trae las actividades de Strava vía API y actualiza activities.json (y, opcionalmente,
  los datos embebidos en index.html / graficos.html).

.DESCRIPTION
  Reproduce el flujo usado para construir este dashboard:
    1. Intercambia un refresh token (o un código de autorización la primera vez) por un access token.
    2. Pagina GET /athlete/activities hasta traer todas las actividades.
    3. Mapea los campos de Strava a un esquema compacto (d,n,t,es,dm,vm,va,eg,ha,hm,cd,wt).
    4. Escribe activities.json y, si se pide, sustituye el bloque de datos embebido
       en los dos HTML del dashboard.

  Requiere una app registrada en https://www.strava.com/settings/api
  (Authorization Callback Domain = "localhost").

.PARAMETER ClientId
  Client ID de tu app de Strava.

.PARAMETER ClientSecret
  Client Secret de tu app de Strava. Nunca lo guardes en este repositorio.

.PARAMETER RefreshToken
  Refresh token de una autorización previa. Si lo tienes, no hace falta -AuthCode.

.PARAMETER AuthCode
  Código de autorización de un solo uso (parámetro "code" de la URL de redirección),
  solo necesario la primera vez. Genera la URL de autorización con:
    https://www.strava.com/oauth/authorize?client_id=TU_CLIENT_ID&redirect_uri=http%3A%2F%2Flocalhost&response_type=code&scope=activity:read_all&approval_prompt=auto

.PARAMETER UpdateDashboards
  Si se indica, además de escribir activities.json, sustituye los datos embebidos
  en index.html y graficos.html (deben estar en la misma carpeta).

.EXAMPLE
  # Primera vez (con el código de la URL de autorización):
  ./fetch_strava_activities.ps1 -ClientId 12345 -ClientSecret xxxx -AuthCode abc123 -UpdateDashboards

.EXAMPLE
  # Actualizaciones posteriores (ya tienes refresh token):
  ./fetch_strava_activities.ps1 -ClientId 12345 -ClientSecret xxxx -RefreshToken yyyy -UpdateDashboards
#>

param(
  [Parameter(Mandatory=$true)][string]$ClientId,
  [Parameter(Mandatory=$true)][string]$ClientSecret,
  [string]$RefreshToken,
  [string]$AuthCode,
  [string]$RedirectUri = "http://localhost",
  [switch]$UpdateDashboards
)

$ErrorActionPreference = "Stop"

if (-not $RefreshToken -and -not $AuthCode) {
  $encodedRedirect = [uri]::EscapeDataString($RedirectUri)
  Write-Host "No se ha dado -RefreshToken ni -AuthCode. Abre esta URL, autoriza, y pasa el 'code' de la redirección como -AuthCode:"
  Write-Host "https://www.strava.com/oauth/authorize?client_id=$ClientId&redirect_uri=$encodedRedirect&response_type=code&scope=activity:read_all&approval_prompt=auto"
  exit 1
}

# --- 1. Obtener access token ---
if ($RefreshToken) {
  $tokenResp = Invoke-RestMethod -Method Post -Uri "https://www.strava.com/oauth/token" -Body @{
    client_id     = $ClientId
    client_secret = $ClientSecret
    refresh_token = $RefreshToken
    grant_type    = "refresh_token"
  }
} else {
  $tokenResp = Invoke-RestMethod -Method Post -Uri "https://www.strava.com/oauth/token" -Body @{
    client_id     = $ClientId
    client_secret = $ClientSecret
    code          = $AuthCode
    grant_type    = "authorization_code"
  }
  Write-Host "Guarda este refresh_token para futuras ejecuciones (no lo subas a git):"
  Write-Host $tokenResp.refresh_token
}

$accessToken = $tokenResp.access_token
Write-Host "Autenticado como $($tokenResp.athlete.firstname) $($tokenResp.athlete.lastname) (id $($tokenResp.athlete.id))"

# --- 2. Paginar /athlete/activities ---
$headers = @{ Authorization = "Bearer $accessToken" }
$all = @()
$page = 1
do {
  $batch = Invoke-RestMethod -Uri "https://www.strava.com/api/v3/athlete/activities?per_page=200&page=$page" -Headers $headers
  $all += $batch
  Write-Host "Página $page -> $($batch.Count) actividades"
  $page++
} while ($batch.Count -gt 0)

Write-Host "Total actividades: $($all.Count)"

# --- 3. Mapear al esquema compacto del dashboard ---
$typeMap = @{
  "Run"="Carrera"; "TrailRun"="Carrera"; "VirtualRun"="Carrera";
  "Ride"="Bicicleta"; "MountainBikeRide"="Bicicleta"; "GravelRide"="Bicicleta"; "EBikeRide"="Bicicleta"; "VirtualRide"="Bicicleta"; "EMountainBikeRide"="Bicicleta"; "Velomobile"="Bicicleta"; "Handcycle"="Bicicleta";
  "Hike"="Senderismo";
  "Walk"="Caminata";
  "AlpineSki"="Esquí alpino"; "BackcountrySki"="Esquí alpino"; "NordicSki"="Esquí alpino"; "Snowboard"="Esquí alpino";
  "Workout"="Entrenamiento"; "WeightTraining"="Entrenamiento"; "Yoga"="Entrenamiento"; "Crossfit"="Entrenamiento"; "StairStepper"="Entrenamiento"; "Elliptical"="Entrenamiento"; "HighIntensityIntervalTraining"="Entrenamiento"; "Pilates"="Entrenamiento"
}
function Map-Type($sportType, $type) {
  $key = if ($sportType) { $sportType } else { $type }
  if ($typeMap.ContainsKey($key)) { return $typeMap[$key] }
  return $key
}

$mapped = foreach ($a in $all) {
  [PSCustomObject]@{
    d  = ($a.start_date -replace 'Z$','')
    n  = $a.name
    t  = Map-Type $a.sport_type $a.type
    es = if ($a.elapsed_time) { [double]$a.elapsed_time } else { 0 }
    dm = if ($a.distance) { [double]$a.distance } else { 0 }
    vm = if ($a.max_speed) { [double]$a.max_speed } else { 0 }
    va = if ($a.average_speed) { [double]$a.average_speed } else { 0 }
    eg = if ($a.total_elevation_gain) { [double]$a.total_elevation_gain } else { 0 }
    ha = if ($a.average_heartrate) { [double]$a.average_heartrate } else { 0 }
    hm = if ($a.max_heartrate) { [double]$a.max_heartrate } else { 0 }
    cd = if ($a.average_cadence) { [double]$a.average_cadence } else { 0 }
    wt = if ($a.average_watts) { [double]$a.average_watts } else { 0 }
  }
}
$mapped = $mapped | Sort-Object d

$outPath = Join-Path $PSScriptRoot "activities.json"
$json = $mapped | ConvertTo-Json -Depth 3 -Compress
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)
Write-Host "Escrito $outPath ($($mapped.Count) actividades)"

# --- 4. (Opcional) actualizar los HTML del dashboard ---
if ($UpdateDashboards) {
  $bytes = [System.IO.File]::ReadAllBytes($outPath)
  $b64 = [Convert]::ToBase64String($bytes)
  foreach ($file in @("index.html","graficos.html")) {
    $htmlPath = Join-Path $PSScriptRoot $file
    if (-not (Test-Path $htmlPath)) { Write-Host "Aviso: no encontrado $htmlPath, se omite"; continue }
    $html = Get-Content -Path $htmlPath -Raw -Encoding UTF8
    $pattern = '(?<=<script id="raw-data-b64" type="text/plain">)[^<]+(?=</script>)'
    if ($html -notmatch $pattern) { Write-Host "Aviso: marcador de datos no encontrado en $file"; continue }
    $newHtml = [regex]::Replace($html, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $b64 })
    [System.IO.File]::WriteAllText($htmlPath, $newHtml, $utf8NoBom)
    Write-Host "Actualizado $file"
  }
}
