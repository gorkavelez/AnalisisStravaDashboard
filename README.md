# Bitácora Deportiva

Dashboard personal de actividades deportivas (carrera, bici, senderismo, caminata...),
con los datos obtenidos directamente de la [API de Strava](https://developers.strava.com/).

## Contenido

- **`index.html`** — panel principal: KPIs, reparto por deporte, kilómetros
  por año/mes, calendario de actividad (heatmap), récords personales y tabla de
  actividades (ordenable por cualquier columna).
- **`graficos.html`** — página de gráficos: volumen mensual, reparto semanal,
  desnivel acumulado y evolución del ritmo de carrera.
- **`activities.json`** — snapshot de las actividades tal y como las devuelve la API de
  Strava, ya mapeadas al esquema compacto que usan los dashboards (ver más abajo).
- **`fetch_strava_activities.ps1`** — script de PowerShell con la lógica de conexión a
  la API: intercambio OAuth, paginación de `/athlete/activities`, mapeo de campos y
  (opcionalmente) reinyección de los datos en los dos HTML.

Ambos HTML son **autocontenidos**: los datos van embebidos en base64 dentro de un
`<script type="text/plain">`, así que se pueden abrir directamente en un navegador o
publicarse tal cual (por ejemplo como Artifact de Claude), sin depender de
`activities.json` en tiempo de ejecución. `activities.json` se guarda aparte solo como
snapshot legible de "lo que trajo la API".

## Esquema de `activities.json`

Array de objetos con claves cortas para minimizar el tamaño embebido:

| Clave | Significado                              |
|-------|-------------------------------------------|
| `d`   | Fecha/hora de inicio (ISO, sin zona)       |
| `n`   | Nombre de la actividad                     |
| `t`   | Tipo (Carrera, Bicicleta, Senderismo, Caminata, u otro deporte de Strava) |
| `es`  | Tiempo transcurrido (s)                    |
| `dm`  | Distancia (m)                              |
| `vm`  | Velocidad máxima (m/s)                     |
| `va`  | Velocidad media (m/s)                      |
| `eg`  | Desnivel positivo (m)                      |
| `ha`  | Frecuencia cardiaca media                  |
| `hm`  | Frecuencia cardiaca máxima                 |
| `cd`  | Cadencia media                             |
| `wt`  | Vatios medios                              |

No incluye calorías ni pasos: la API de Strava no los da en el listado de
actividades (solo en el detalle de cada una, una a una), así que se dejaron fuera del
dashboard para no depender de cientos de llamadas adicionales.

## Actualizar los datos

Necesitas una app registrada en <https://www.strava.com/settings/api> (campo
**Authorization Callback Domain** = `localhost`). Con el Client ID y Client Secret:

**Primera vez** (necesitas un código de autorización de un solo uso):

1. Abre, sustituyendo tu Client ID:
   ```
   https://www.strava.com/oauth/authorize?client_id=TU_CLIENT_ID&redirect_uri=http%3A%2F%2Flocalhost&response_type=code&scope=activity:read_all&approval_prompt=auto
   ```
2. Autoriza. La redirección a `localhost` fallará al cargar — es normal, copia el
   parámetro `code=` de la URL resultante.
3. Ejecuta:
   ```powershell
   ./fetch_strava_activities.ps1 -ClientId TU_CLIENT_ID -ClientSecret TU_CLIENT_SECRET -AuthCode EL_CODIGO -UpdateDashboards
   ```
4. El script imprime un `refresh_token` — guárdalo (fuera del repo) para no tener que
   repetir la autorización cada vez.

**Siguientes veces:**

```powershell
./fetch_strava_activities.ps1 -ClientId TU_CLIENT_ID -ClientSecret TU_CLIENT_SECRET -RefreshToken TU_REFRESH_TOKEN -UpdateDashboards
```

Esto reescribe `activities.json` y actualiza los datos embebidos en ambos HTML.

## Seguridad

**Nunca subas tu Client Secret, access token ni refresh token a este repositorio.**
Pásalos como parámetros o variables de entorno al ejecutar el script; no los
hardcodees en ningún fichero versionado.

## Limitación conocida

Los HTML publicados (por ejemplo como Artifact) no pueden llamar a la API de Strava
por sí mismos: la política de seguridad del entorno de publicación bloquea peticiones
de red salientes a dominios externos. Por eso la actualización de datos es un paso
manual (este script), no una conexión en vivo dentro de la página.
