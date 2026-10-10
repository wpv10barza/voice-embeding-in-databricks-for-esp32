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
