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


## Dictado en vivo: EDITAR ORDEN 3C abierto

No hace falta un micrófono ni un botón físico en el ESP32. Abra
**EDITAR ORDEN 3C** en la pantalla y deje ese editor abierto, sin
escribir nada manualmente. El firmware corregido muestra
`VOZ PC: LISTO` y permite reemplazar su ejemplo de texto por el
borrador recibido desde Databricks; protege cualquier texto que
usted haya comenzado a editar con el teclado táctil.

Abra **Windows PowerShell** (reconocimiento de voz español instalado),
en la carpeta del cliente, y escriba:

```powershell
cd C:\Users\ASUS\erp-mantto-esp32\voice-embeding-in-databricks-for-esp32
git pull --ff-only origin main
.\scripts\Activar-Microfono3C.ps1
```

PowerShell mostrará `[DATABRICKS] LISTO` cuando la API y bandeja
respondan. Pulse **ENTER en PowerShell** para activar el micrófono del
PC, hable durante hasta 15 segundos, lea la transcripción y confirme
con `S` si desea enviarla al editor. Se consultará el estado de
entrega hasta `delivered_to_editor`. Pulse `X` para terminar la sesión
de voz. **Nunca** hay escritura automática de Google Sheets.

También admite una sola orden:

```powershell
.\scripts\Enviar-Voz3C.ps1 -Microfono -EsperarEntrega
```

**Qué realiza cada modo:** `-Microfono` es reconocimiento local de
voz de Windows; usa Databricks como canal de entrega al ESP32, **no**
es transcripción por Gemini. Si desea que **Gemini en Databricks**
transcriba el audio, grabe un archivo WAV/MP3 en el PC y ejecute:

```powershell
.\scripts\Enviar-Voz3C.ps1 -AudioFile "C:\grabaciones\orden.wav" -EsperarEntrega
```

El resultado `model_configured=true` solo demuestra que hay clave
configurada; una transcripción de audio correcta confirma una inferencia
real de Gemini. Para verificar la entrega física es necesario tener
el firmware corregido **instalado**, Wi-Fi/OAuth funcionales y el
`device_id` correspondiente al cliente PowerShell. No confunda la
compilación con el flasheo por COM9.


## Motores de voz comparados (octubre 2026)

Las frases incorrectas como «Tras diablo» proceden de
`System.Speech.Recognition` de Windows, no de una inferencia Gemini.

Se ofrecen tres motores con un solo script:

| `-Motor` | Reconocimiento | Clave externa | Cómo envía a Databricks |
| --- | --- | --- | --- |
| `Gemini` (predeterminado) | Se graba WAV 16 kHz en el PC y se transcribe mediante `/api/device/v1/voice/transcribe` | Usa `GEMINI_API_KEY` **dentro de Databricks** | Resultado de transcripción → borrador 3C |
| `Wispr` | Wispr Flow Windows dicta al campo activo `Read-Host` (atajo configurable, frecuentemente Ctrl+Win) | No hace falta API de Wispr | Texto dictado en PowerShell → borrador 3C |
| `Windows` | Reconocedor clásico local `System.Speech` | Ninguna | Texto reconocido → borrador 3C; modo de respaldo, menor calidad observada |

### Primera prueba con Gemini directamente desde el micrófono

```powershell
cd C:\Users\ASUS\erp-mantto-esp32\voice-embeding-in-databricks-for-esp32
git pull --ff-only origin main

# Instalar solamente una vez la biblioteca de captura del microfono.
py -m pip install sounddevice

.\scripts\Activar-Microfono3C.ps1 -Motor Gemini
```

Al pulsar Enter, `Grabar-Microfono3C.py` graba 10 s de audio mono a
16 kHz y lo guarda **temporalmente** en el PC; `Enviar-Voz3C.ps1`
lo envía por HTTPS a tu aplicación Databricks. La app pide una transcripción
real a Gemini (el modelo actual es `VOICE_GEMINI_MODEL=gemini-2.5-flash`),
devuelve el texto y solicita revisión antes de transmitir el borrador al
ESP32. El WAV temporal se borra al finalizar incluso si hay un error.
No se usan ni el servicio clásico de reconocimiento Windows ni el
micrófono del ESP32.

Si aparece «Micrófono no disponible», revise en Configuración de Windows
los permisos de micrófono de las aplicaciones de escritorio y su
dispositivo de entrada predeterminado. Opcionalmente se puede indicar
`-MicrofonoDispositivo N` para un índice de entrada PortAudio válido.

### Usar Wispr Flow como opción intermedia

Instalar [Wispr Flow para Windows](https://wisprflow.ai/downloads).
La documentación de Wispr describe un **dictado que pega texto en la
aplicación activa** (incluida una terminal). No se identificó una API
pública oficial de transcripción para llamarla directamente desde la app
Databricks. La integración es por el texto que Wispr inserta en PowerShell.

```powershell
.\scripts\Activar-Microfono3C.ps1 -Motor Wispr
```

Pulse **Enter** para abrir el campo de dictado, mantenga el foco en
esa línea, active la combinación de Wispr Flow (su atajo configurado),
hable y termine el dictado. Compruebe la frase que aparece y pulse
**Enter**. PowerShell la enviará como borrador al backend, solicitando
primero confirmación. No se ejecutan órdenes 3C automáticamente ni se
escribe en Google Sheets.

**Modelos alternativos por API:** Deepgram Nova-3 y OpenAI
`gpt-4o-transcribe` disponen de APIs de transcripción utilizables desde
Databricks pero requerirían otra clave. El especializado
`gemini-3.5-transcribe` también está documentado; requiere la nueva
Interactions API y pruebas de compatibilidad del SDK antes de habilitarlo
en producción. Esta actualización no cambia automáticamente el modelo
servidor ni despliega otra app.

Documentación: [Wispr en terminales](https://docs.wisprflow.ai/articles/6478598909-using-flow-with-linux-wsl-and-terminal-applications),
[Gemini audio](https://ai.google.dev/gemini-api/docs/transcribe),
[Deepgram](https://developers.deepgram.com/docs/pre-recorded-audio).


## Solución de Gemini HTTP 503 y Wispr sin texto

El error `[DATABRICKS/GEMINI] ... HTTP 503` no demuestra que la grabación
WAV esté dañada. El backend anterior devolvía un mensaje genérico para
cualquier fallo `google.genai.errors.APIError`; `/voice/health` solo
verifica que la clave está configurada, no que la API funcione.

**Despliegue del backend con diagnóstico Gemini** (compilación/CI
aprobada en GitHub, pero aún necesita despliegue en tu Databricks Apps):

```powershell
databricks apps deploy asistente-cloud-erp `
  --git-commit 8ce58259281e8bf3aedb01347f79f9ebab004ad9 `
  --profile asistente-cloud-erp --timeout 10m
```

**Primero pruebe Gemini sin audio** desde este repositorio:

```powershell
git pull --ff-only origin main
.\scripts\Probar-Gemini3C.ps1
```

El nuevo `POST /api/device/v1/voice/probe` hace una inferencia real corta
y devuelve `inference_confirmed=true` solo si Gemini responde. En un
fallo devuelve información saneada `provider_http`, `provider_status`
y `hint`: códigos 401/403 (credenciales/permisos); 404 (modelo); 429
(cuota); 500/503 (servicio proveedor). No incluye respuestas crudas,
claves, audio ni contenido privado de las transcripciones. La prueba
consume una pequeña cuota y no modifica Google Sheets.

Después ejecute `./scripts/Activar-Microfono3C.ps1 -Motor Gemini`.
Este modo primero comprueba que Gemini realmente responde, luego graba
un WAV de 10 segundos y lo envía a Databricks. Una inferencia de texto
aprobada **no garantiza** la transcripción del audio: la segunda prueba
debe pasar también.

**Si Wispr queda vacío en PowerShell**:

1. Compruebe que Wispr Flow esté **instalado y ejecutándose**, con el
   micrófono autorizado en Windows.
2. Mantenga el foco en la línea
   `WISPR FLOW - dicta aqui tu orden 3C:` y use el atajo que tenga
   configurado Wispr (por defecto, `Ctrl+Win`).
3. Si Wispr transcribió pero no pegó texto, use `Shift+Alt+Z` para
   *Pegar última transcripción* en Windows, o `Shift+Alt+X` para copiarla
   y después `Ctrl+V` en el prompt. El script permitirá un segundo
   intento antes de cancelar sin enviar nada.

Wispr solo inserta texto como cualquier aplicación de dictado. No existe
una conexión directa de Wispr Flow a tu App de Databricks implementada
aquí. La bandeja 3C sigue requiriendo confirmación humana y no modifica
Google Sheets automáticamente.


## Octubre 2026: Solución de Gemini 404 NOT_FOUND

`Probar-Gemini3C.ps1` mostró `Gemini HTTP real: 404` al consultar
`gemini-2.5-flash`. Google restringe el acceso a esa generación para
proyectos nuevos. En el backend actualizado se utiliza
**`gemini-3.8-flash`** tanto para voz como para interpretación 3C;
admite entrada de audio, está generalmente disponible y el
código elimina controles de muestreo antiguos incompatibles.

Código actualizado (CI aprobada):
`wpv10barza/asistente-de-databricks--erp` commit
`b2d8f64b0e968a337c49b0c4babca8078f979015`.

### Implementar en Databricks

```powershell
databricks apps deploy asistente-cloud-erp `
  --git-commit b2d8f64b0e968a337c49b0c4babca8078f979015 `
  --profile asistente-cloud-erp `
  --timeout 10m
```

Después actualizar scripts y verificar **primero los modelos visibles**
mediante `GET /api/device/v1/voice/models` (protegido). Ese endpoint
solo muestra nombres de una lista permitida, nunca credenciales.
`Probar-Gemini3C.ps1` muestra la lista y, después, realiza una
inferencia real con `gemini-3.8-flash`:

```powershell
git pull --ff-only origin main
.\scripts\Probar-Gemini3C.ps1
.\scripts\Activar-Microfono3C.ps1 -Motor Gemini
```

**ATENCIÓN:** una lista de modelos, `/voice/health` o CI verde no
garantizan que la API funcione con la clave real ni que transcriba audio.
La inferencia real puede consumir cuota y debe confirmarse desde Windows.

Si `gemini-3.8-flash` no aparece en los modelos visibles de esa clave
o devuelve otro 404, revisar acceso de la clave en Google AI Studio;
el endpoint de modelos permite descubrir `gemini-3.6-flash` o
`gemini-3.5-flash-lite` como alternativas. No repetir automáticamente
una inferencia de pago ni enviar órdenes si el modelo falla.

Fuentes:
https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash
https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash
https://ai.google.dev/gemini-api/docs/generate-content/audio


## Dictado transcribe otra frase / ESP32 sigue queued_for_editor (video 10-10-2026)

Si `Probar-Gemini3C.ps1` muestra `[PASS]`, y `Activar-Microfono3C.ps1`
muestra un WAV de 320044 bytes y una transcripción, **Gemini funciona**
pero eso no demuestra que el micrófono elegido haya grabado la orden
correcta. Por ejemplo, una transcripción sobre «el micrófono de Windows»
en vez de «cambiar la periodicidad de lubricación» puede indicar que
se capturó audio del sistema, un tutorial o una fuente de entrada equivocada.

Antes de enviar borradores, pruebe localmente:

```powershell
cd C:\Users\ASUS\erp-mantto-esp32\voice-embeding-in-databricks-for-esp32
git -c http.version=HTTP/1.1 pull --ff-only origin main

# Muestra nombre, ID y entrada predeterminada; sin usar Databricks
.\scripts\Probar-Captura3C.ps1 -Listar

# Sustituir 1 por el ID del MICROFONO, no Stereo Mix/mezcla estéreo
.\scripts\Probar-Captura3C.ps1 -MicrofonoDispositivo 1 -Segundos 6
```

El script graba, muestra el nivel RMS, reproduce el audio localmente
para que se escuche qué capturó realmente y borra el WAV temporal.
No usa tokens, no consulta Databricks ni modifica Google Sheets. Si oye
la narración de otro programa, cierre reproducción de fondo y cambie
el dispositivo de entrada. Si oye silencio, revise el volumen y los
permisos de micrófono de Windows.

Cuando la captura sea correcta:

```powershell
.\scripts\Activar-Microfono3C.ps1 -Motor Gemini -MicrofonoDispositivo 1
```

Ahora se muestra el nombre de la fuente elegida, RMS y pico antes de
enviar el audio a Gemini. El cliente REST decodifica la respuesta JSON
original en UTF-8, evitando transcripciones deformadas como
`micrÃ³fono` en Windows PowerShell 5.1. Si la transcripción sigue
incorrecta, responda **N** a la pregunta de envío.

**Problema independiente:** `queued_for_editor` significa que el backend
tiene el borrador, pero el ESP32 no confirmó abrirlo. La última
compilación de firmware, aun aprobada, **no equivale a instalación**
en el dispositivo. Elija **Wi-Fi 2.4 GHz** en el firmware actualizado
para leer la IP DHCP real; después ejecute:

```powershell
.\scripts\Diagnosticar-PanelESP32.ps1 -PanelUrl "http://IP_REAL_DEL_PANEL"
```

Compruebe `fw_commit`, `device_id`, `voice_poll_count`,
`voice_poll_http` y `voice_ack_http`. No use literalmente
`http://IP_DEL_ESP32`. La cola actual de Databricks es en memoria;
replicas o reinicios pueden provocar entregas pendientes. No se envían
órdenes finales ni cambios a Sheets sin aprobación humana.


## Espejo de conexión cloud (sin la IP LAN del ESP32)

Con el backend Databricks actualizado, consulte desde PowerShell:
- .\scripts\Diagnosticar-Mirror3C.ps1
- .\scripts\Diagnosticar-PanelESP32.ps1

El segundo comando ahora recurre al espejo Databricks si omite la IP o
escribe un texto de ejemplo IP_REAL_DEL_ESP32. Se necesita el token de
Device API y, si corresponde, OAuth del perfil de Databricks. Los
endpoints consultados son de solo lectura; no ejecutan ordenes ni
escriben Google Sheets.

La consulta /api/device/v1/voice/sync comprueba si el ESP32 consulto
su bandeja HTTPS recientemente (sin IP LAN), cuantos borradores siguen
pendientes y cuantos recibieron ACK. Estado panel_seen_recently=true
NO garantiza que la pantalla este abierta ni que una orden se haya
aplicado. Si el backend muestra memory_only, configure la variable
VOICE_DRAFT_STORE_PATH a un archivo en UC Volume escribible y
despliegue el backend para disponer de persistencia entre reinicios.
Ese fichero solo se admite para un backend de una instancia; no ofrece
alta disponibilidad multirreplica ni elimina cortes fisicos de Wi-Fi.
