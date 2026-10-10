# Voz 3C — Windows PowerShell → Databricks → ESP32

Módulo complementario del [backend Databricks](https://github.com/wpv10barza/asistente-de-databricks--erp)
y del [firmware ESP32](https://github.com/wpv10barza/erp-mantto-esp32).

**Repositorio separado:** contiene el cliente de voz/diagnóstico en PowerShell y
sus pruebas. Los endpoints desplegables viven en el backend Databricks,
porque Databricks Apps despliega **un repositorio fuente por aplicación**.
No se habilita un segundo runtime ni un backend LAN.

## Flujo

`Archivo WAV/MP3 o micrófono del PC → PowerShell → Gemini en Databricks
(voz a texto) → borrador protegido → consulta periódica ESP32 →
EDITAR ORDEN 3C → confirmación táctil → Device API →
revisión humana → eventual aplicación en Google Sheets`

Los comandos de voz **no escriben Google Sheets directamente**.
El panel ESP32 no requiere micrófono. La bandeja en el backend es de
memoria con TTL 15 minutos; no garantiza entrega a través de reinicios
o múltiples réplicas hasta instalar un almacén persistente compartido.

## Comprobaciones

`scripts/Probar-Extremo3C.ps1` verifica salud del backend, Google Sheets
real mediante lectura `Data!A4:AF4`, autenticación de la Device API y
disponibilidad del módulo de voz, sin cambiar una celda.

`scripts/Enviar-Voz3C.ps1` admite tres entradas:
`-Texto "Revisar..."`, `-AudioFile .\orden.wav` (transcribe en
Databricks) o `-Microfono` (dictado Windows compatible, si existe).
Muestra la transcripción y exige confirmación antes de crear un
borrador destinado a `panel-4848s040-3c-01`.

En equipos con idioma español no instalado, la opción `-Microfono`
puede no estar disponible; grabe un archivo WAV con Grabadora de
sonido de Windows y utilice `-AudioFile`.

## Credenciales

Las dos capas de seguridad pueden solicitar:
- `DATABRICKS_ACCESS_TOKEN` (OAuth de Databricks Apps); el script intenta
  obtenerlo del perfil `asistente-cloud-erp` con Databricks CLI.
- `ESP32_API_TOKEN` (token Device API de Databricks, distinto del OAuth).

No suba contraseñas, tokens ni grabaciones privadas a GitHub.
`ALLOW_SHEET_WRITE=false` es el valor conservador.
`GEMINI_API_KEY` se consume solo dentro de Databricks Apps.

## Despliegue

Primero se debe desplegar un commit del
[backend Databricks](https://github.com/wpv10barza/asistente-de-databricks--erp)
que incluya `app/voice_3c.py` y configurar el recurso de Gemini.
Después se actualiza el firmware ESP32 para que consulte
`GET /api/device/v1/voice/inbox/panel`.

Un HTTP 200 en `/api/health` **no** es prueba de lectura de Sheets.
Solo `/api/device/v1/cloud/verify` confirma acceso y esquema real.

Se tomó como referencia conceptual el flujo Gemini Live del archivo
OmniBot aportado por el usuario, sin copiar su servidor local ni sus
dependencias de robots y reconocimiento facial.

## Si `Probar-EntregaEditor.ps1` queda en queued_for_editor

**La API acepta el borrador, pero el ESP32 todavía no ha acusado recibo.**
No implica fallo de Google Sheets. Primero compruebe si el firmware fue
**cargado físicamente**: `pio run` compila y `pio run -t upload` flashea.

En el panel, abra **Wi-Fi 2.4 GHz** y copie la **IP local**, sin compartir
contraseñas. Desde PowerShell, en la carpeta de este repositorio:

```powershell
.\scripts\Diagnosticar-PanelESP32.ps1 -PanelUrl "http://IP_LOCAL_DEL_ESP32"

.\scripts\Probar-EntregaEditor.ps1 -EjecutarPrueba `
  -PanelUrl "http://IP_LOCAL_DEL_ESP32"
```

El diagnóstico es de **solo lectura** y muestra el commit realmente
instalado, `device_id`, conexión Wi-Fi, las consultas de voz y sus
HTTP, el acuse de recibo y si hubo un borrador abierto en el editor.
El firmware principal contiene ahora **reintentos del ACK** cada 6 s.

Si `/health` no presenta `voice_poll_count`, se está ejecutando un
firmware anterior a la actualización de diagnóstico. La compilación
`SUCCESS` en Windows no basta: conecte COM9 (o el COM realmente
detectado) y ejecute:

```powershell
cd "$HOME\erp-mantto-esp32"
git pull --ff-only origin main
py -m platformio run -e panel_4848s040 -t upload --upload-port COM9
py -m platformio device monitor --port COM9 --baud 115200
```

Si el contador `voice_poll_count` aumenta pero el HTTP no es 200,
resuelva el estado indicado (OAuth M2M, Device API token, permisos
Databricks Apps o endpoint). Si el `device_id` local es distinto,
utilice el ID verdadero en `-DeviceId` al enviar el borrador.
Si `voice_poll_http=200` con bandeja vacía pero PowerShell ve un
borrador pendiente, compruebe que ambas solicitudes alcanzan la misma
instancia Databricks: la bandeja actual es en memoria y no soporta
garantías entre réplicas o reinicios.

Los borradores caducan a los 15 minutos. No se modifica Google Sheets.
Las cadenas con acentos se interpretan correctamente desde Windows
PowerShell 5.1 porque los scripts se guardaron con codificación UTF-8 BOM.

## Uso en Windows PowerShell

Los comandos se ejecutan **en Windows**, dentro de la carpeta
`voice-embeding-in-databricks-for-esp32`. Copie primero las credenciales
en el entorno del proceso (no en el repositorio): `ESP32_API_TOKEN` y, si
el workspace lo exige, `DATABRICKS_ACCESS_TOKEN`. El primer script pide
el token Device API de forma oculta cuando no está en el entorno e
intenta obtener el token de Databricks del perfil CLI.

```powershell
.\scripts\Probar-Extremo3C.ps1
.\scripts\Enviar-Voz3C.ps1 -Texto "Revisa la estrategia de la tarea 123"
.\scripts\Enviar-Voz3C.ps1 -AudioFile "C:\grabaciones\orden.wav" -VistaPreviaIA
.\scripts\Enviar-Voz3C.ps1 -Microfono
.\scripts\Probar-EntregaEditor.ps1 -EjecutarPrueba
```

`-Microfono` utiliza el motor de dictado en español que Windows tenga
instalado. `-AudioFile` sí transcribe dentro de Databricks mediante el
modelo Gemini configurado. `-VistaPreviaIA` realiza un análisis
adicional, opcional y sin escritura en Sheets.

El diagnóstico básico ejecuta **solo GET**. Si desea confirmar que el
ESP32 físico recibió el texto, use la prueba adicional
`Probar-EntregaEditor.ps1`, que solicita consentimiento, envía un
borrador con la leyenda **NO ENVIAR** y espera el ACK del panel. Una
confirmación `delivered_to_editor` no prueba que Sheets haya cambiado:
esa modificación exige una propuesta, aprobación humana y escritura
del backend expresamente habilitada.

**Limitaciones importantes:** la app Databricks debe haberse
desplegado con el módulo `app/voice_3c.py` y la aplicación ESP32 debe
ejecutar una imagen que incluya `pollVoiceDraft`. Los cambios de
GitHub no actualizan por sí solos el backend desplegado ni la memoria
flash del ESP32.
