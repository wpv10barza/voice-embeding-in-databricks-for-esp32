"""Dictar PC 3C: Windows desktop relay for the native Wispr Flow dictation app.

The app NEVER records microphone audio or transcribes text. Wispr Flow pastes
completed dictation into the focused Tk text field. Only while the relay is ON,
the stable text is queued as a NON-EXECUTABLE draft in Databricks. The ESP32
must still open EDITAR ORDEN 3C; actual command/Sheets approval stays manual.

No global clipboard monitoring, no global keystroke hooks, no saved credentials.
"""
from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import threading
import time
import tkinter as tk
import urllib.error
import urllib.parse
import urllib.request
import uuid
from tkinter import messagebox, scrolledtext, simpledialog, ttk

APP_URL = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com"
PROFILE = "asistente-cloud-erp"
DEFAULT_DEVICE = "panel-4848s040-3c-ota-2f26ec3f"
QUIET_SECONDS = 2.2
ACK_TIMEOUT = 80
MAX_EDITOR_BYTES = 230


def normalize_draft(raw: str) -> str:
    """Same non-executable text size/character contract as the ESP32 editor."""
    clean = " ".join(str(raw or "").split())
    clean = "".join(ch for ch in clean if ch.isprintable()).strip()
    if not clean:
        raise ValueError("Todavia no hay una transcripcion de Wispr.")
    if len(clean.encode("utf-8")) > MAX_EDITOR_BYTES:
        raise ValueError("Orden demasiado larga: maximo 230 bytes UTF-8.")
    return clean


def read_oauth_token() -> str:
    for name in ("DATABRICKS_ACCESS_TOKEN", "DATABRICKS_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    try:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        result = subprocess.run(
            ["databricks", "auth", "token", "--profile", PROFILE, "--output", "json"],
            capture_output=True, text=True, timeout=18, creationflags=flags,
            check=False,
        )
        if result.returncode == 0:
            return str(json.loads(result.stdout).get("access_token", "")).strip()
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return ""


def call_cloud(path: str, device_token: str, oauth: str, data: dict | None = None) -> dict:
    headers = {"Accept": "application/json", "X-3C-Device-Token": device_token}
    if oauth:
        headers["Authorization"] = "Bearer " + oauth
    encoded = None
    if data is not None:
        encoded = json.dumps(data, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(
        APP_URL + path, data=encoded, headers=headers,
        method="POST" if data is not None else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=18) as response:
            if not str(response.headers.get("Content-Type", "")).startswith("application/json"):
                raise RuntimeError("Databricks no devolvio JSON; compruebe OAuth.")
            return json.loads(response.read(240000).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError("Databricks HTTP " + str(exc.code)) from None
    except (urllib.error.URLError, TimeoutError) as exc:
        raise RuntimeError("No se pudo conectar con Databricks (red/DNS/TLS).") from None


class DictarPC3C:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("DICTAR PC 3C | Wispr Flow -> Databricks -> ESP32")
        root.geometry("760x635")
        root.minsize(660, 540)

        self.events: queue.Queue = queue.Queue()
        self.oauth = ""
        self.device_token = ""
        self.connected = False
        self.active = False
        self.busy = False
        self.pending_id = ""
        self.pending_since = 0.0
        self.last_contents = ""
        self.last_change = time.monotonic()
        self.last_sent_contents = ""
        self.device_var = tk.StringVar(value=DEFAULT_DEVICE)
        self.status_var = tk.StringVar(value="DESCONECTADO: pulse CONECTAR.")
        self.state_var = tk.StringVar(value="PUENTE APAGADO")
        self._build()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(250, self.tick)

    def _build(self) -> None:
        frame = ttk.Frame(self.root, padding=16)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="DICTAR PC 3C — Wispr Flow", font=("Segoe UI", 18, "bold")).pack(anchor="w")
        ttk.Label(
            frame, wraplength=715, justify="left",
            text="Dictado original de Wispr. Mantenga esta ventana al frente. "
                 "Ctrl + Win = mantener y hablar; Ctrl + Win + Espacio = manos libres "
                 "(atajos predeterminados configurables en Wispr). "
                 "No usa Gemini ni graba audio por separado.",
        ).pack(anchor="w", pady=(6, 12))
        controls = ttk.Frame(frame)
        controls.pack(fill="x")
        ttk.Label(controls, text="Device ID del ESP32:").pack(side="left")
        ttk.Entry(controls, textvariable=self.device_var, width=30).pack(side="left", padx=(8, 10))
        self.connect_button = ttk.Button(controls, text="CONECTAR", command=self.connect)
        self.connect_button.pack(side="left")
        ttk.Label(frame, textvariable=self.status_var, foreground="#285b8a",
                  wraplength=710).pack(anchor="w", pady=(12, 4))
        action = ttk.Frame(frame)
        action.pack(fill="x", pady=(8, 8))
        self.toggle_button = ttk.Button(
            action, text="ACTIVAR ENVIO AUTOMATICO", command=self.toggle,
            state="disabled",
        )
        self.toggle_button.pack(side="left")
        ttk.Label(action, textvariable=self.state_var, font=("Segoe UI", 10, "bold")).pack(
            side="left", padx=18,
        )
        ttk.Label(frame, text="Texto dictado por Wispr (deje el cursor aqui):",
                  font=("Segoe UI", 11, "bold")).pack(anchor="w", pady=(6, 4))
        self.editor = tk.Text(frame, height=6, wrap="word", font=("Segoe UI", 12),
                              undo=True)
        self.editor.pack(fill="x")
        helpers = ttk.Frame(frame)
        helpers.pack(fill="x", pady=(8, 4))
        ttk.Button(helpers, text="ENFOCAR CAMPO", command=self.editor.focus_set).pack(side="left")
        ttk.Button(helpers, text="VACIAR TEXTO", command=self.clear).pack(side="left", padx=8)
        ttk.Button(helpers, text="ENVIAR BORRADOR AHORA", command=self.send_now).pack(side="left")
        ttk.Label(
            frame, text="Si Wispr no pega: con el cursor en el campo, Shift + Alt + Z "
                        "recupera la ultima transcripcion.",
            wraplength=700, justify="left",
        ).pack(anchor="w", pady=(6, 8))
        ttk.Label(frame, text="Estado de entrega y diagnostico:",
                  font=("Segoe UI", 10, "bold")).pack(anchor="w")
        self.logbox = scrolledtext.ScrolledText(frame, height=7, state="disabled",
                                                wrap="word", font=("Consolas", 9))
        self.logbox.pack(fill="both", expand=True, pady=(3, 6))
        ttk.Label(
            frame, wraplength=715,
            text="SEGURIDAD: solo envia un borrador a EDITAR ORDEN 3C. "
                 "NO pulsa ENVIAR 3C ni aprueba o escribe Google Sheets. "
                 "El historial y la entrega dependen de Databricks/firmware.",
        ).pack(anchor="w")
        self.log("Abra Wispr Flow en Windows y compruebe que el campo recibe el dictado.")

    def log(self, message: str) -> None:
        self.logbox.configure(state="normal")
        self.logbox.insert("end", time.strftime("%H:%M:%S") + "  " + message + "\n")
        self.logbox.see("end")
        self.logbox.configure(state="disabled")

    def submit_thread(self, kind: str, fn, *args) -> None:
        def execute() -> None:
            try:
                self.events.put((kind, "success", fn(*args)))
            except Exception as exc:
                self.events.put((kind, "error", str(exc)))
        threading.Thread(target=execute, daemon=True).start()

    def connect(self) -> None:
        if self.busy or self.pending_id:
            return
        identifier = self.device_var.get().strip()
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,96}", identifier):
            messagebox.showerror("Device ID", "Introduzca el ID real del dispositivo ESP32.")
            return
        secret = os.getenv("ESP32_API_TOKEN", "").strip()
        if not secret:
            secret = simpledialog.askstring(
                "Conectar Databricks", "ESP32_API_TOKEN (no se guarda):",
                show="*", parent=self.root,
            ) or ""
        if not secret.strip():
            return
        self.device_token = secret.strip()
        self.busy = True
        self.status_var.set("Conectando a Databricks...")
        self.connect_button.configure(state="disabled")
        self.submit_thread("connect", self._connect_remote, self.device_token)

    def _connect_remote(self, device_token: str) -> str:
        oauth = read_oauth_token()
        data = call_cloud("/api/device/v1/voice/health", device_token, oauth)
        if data.get("ok") is not True:
            raise RuntimeError("La API de voz no esta lista.")
        self.oauth = oauth
        return str(data.get("module", "voice-3c"))

    def toggle(self) -> None:
        if not self.connected:
            messagebox.showwarning("Databricks", "Primero conecte la aplicacion.")
            return
        self.active = not self.active
        if self.active:
            self.state_var.set("ACTIVO — esperando Wispr")
            self.toggle_button.configure(text="DESACTIVAR ENVIO")
            self.last_contents = self.editor.get("1.0", "end-1c")
            self.last_change = time.monotonic()
            self.log("Puente ACTIVADO. Dicte en el campo con Wispr Flow.")
            self.editor.focus_set()
        else:
            self.state_var.set("APAGADO — dictado local")
            self.toggle_button.configure(text="ACTIVAR ENVIO AUTOMATICO")
            self.log("Puente DESACTIVADO; Wispr puede seguir funcionando normalmente.")

    def clear(self) -> None:
        if self.busy or self.pending_id:
            self.log("Espere a terminar el envio antes de vaciar la orden.")
            return
        self.editor.delete("1.0", "end")
        self.last_contents = ""
        self.last_change = time.monotonic()
        self.last_sent_contents = ""
        self.editor.focus_set()

    def send_now(self) -> None:
        if not self.connected:
            self.log("Conecte a Databricks primero.")
            return
        if self.busy or self.pending_id:
            self.log("Hay un borrador en proceso o esperando al ESP32.")
            return
        raw = self.editor.get("1.0", "end-1c")
        try:
            text = normalize_draft(raw)
        except ValueError as exc:
            self.log(str(exc))
            return
        self.busy = True
        self.last_sent_contents = raw
        self.status_var.set("Enviando borrador a Databricks...")
        self.log("Enviando borrador (" + str(len(text.encode("utf-8"))) + " bytes).")
        self.submit_thread("submit", self._submit_remote,
                           self.device_var.get().strip(), text)

    def _submit_remote(self, device_id: str, text: str) -> dict:
        return call_cloud(
            "/api/device/v1/voice/drafts", self.device_token, self.oauth,
            {"device_id": device_id,
             "request_id": "wispr-gui-" + uuid.uuid4().hex,
             "text": text},
        )

    def _check_pending(self, draft: str, device_id: str) -> dict:
        # Tk variables must be read only on the UI thread.
        device = urllib.parse.quote(device_id, safe="")
        draft = urllib.parse.quote(draft, safe="")
        return call_cloud(
            "/api/device/v1/voice/drafts/" + draft + "?device_id=" + device,
            self.device_token, self.oauth,
        )

    def process_event(self, event: tuple) -> None:
        kind, outcome, value = event
        self.busy = False
        if outcome == "error":
            self.status_var.set("ERROR: " + str(value))
            self.log("ERROR " + str(value))
            if kind == "connect":
                self.connect_button.configure(state="normal")
                self.connected = False
            return
        if kind == "connect":
            self.connected = True
            self.connect_button.configure(state="normal")
            self.toggle_button.configure(state="normal")
            self.status_var.set("DATABRICKS LISTO (" + str(value) + ")")
            self.log("Databricks conectado. No se requiere Gemini para dictar.")
            self.editor.focus_set()
        elif kind == "submit":
            draft = str(value.get("draft_id", ""))
            if not draft or value.get("status") != "queued_for_editor":
                self.log("ERROR: la API no confirmo el borrador.")
                return
            self.pending_id = draft
            self.pending_since = time.monotonic()
            self.last_change = time.monotonic()
            self.status_var.set("Borrador en Databricks; esperando editor ESP32.")
            self.log("queued_for_editor. No hay cambios en Google Sheets.")
        elif kind == "poll":
            status = str(value.get("status", ""))
            if status == "delivered_to_editor":
                self.log("ESP32 RECIBIDO: borrador abierto en EDITAR ORDEN 3C.")
                self.status_var.set("ESP32 RECIBIDO — revise y confirme en pantalla.")
                self.pending_id = ""
                self.editor.delete("1.0", "end")
                self.last_sent_contents = ""
                self.last_contents = ""
                self.last_change = time.monotonic()
                self.editor.focus_set()
            elif status != "queued_for_editor":
                self.log("Entrega no confirmada: " + (status or "sin estado"))
                self.pending_id = ""
        else:
            self.log("Evento inesperado: " + kind)

    def tick(self) -> None:
        try:
            while True:
                self.process_event(self.events.get_nowait())
        except queue.Empty:
            pass
        if self.active and self.connected and not self.busy and not self.pending_id:
            raw = self.editor.get("1.0", "end-1c")
            now = time.monotonic()
            if raw != self.last_contents:
                self.last_contents = raw
                self.last_change = now
            elif raw.strip() and raw != self.last_sent_contents:
                if now - self.last_change >= QUIET_SECONDS:
                    self.send_now()

        if self.pending_id and not self.busy:
            elapsed = time.monotonic() - self.pending_since
            if elapsed > ACK_TIMEOUT:
                self.status_var.set(
                    "Sin ACK del ESP32. Revise Wi-Fi, firmware y Device ID."
                )
                self.log("queued_for_editor > 80 s: revisar recepcion del ESP32.")
                self.pending_id = ""
                self.active = False
                self.state_var.set("APAGADO — verificar ESP32")
                self.toggle_button.configure(text="ACTIVAR ENVIO AUTOMATICO")
            elif int(elapsed) % 4 == 0:
                if not hasattr(self, "_last_poll") or now_poll() - self._last_poll > 3.5:
                    self._last_poll = now_poll()
                    self.busy = True
                    self.submit_thread("poll", self._check_pending,
                                       self.pending_id, self.device_var.get().strip())
        self.root.after(350, self.tick)

    def close(self) -> None:
        self.active = False
        self.device_token = ""
        self.oauth = ""
        self.root.destroy()


def now_poll() -> float:
    return time.monotonic()


if __name__ == "__main__":
    window = tk.Tk()
    DictarPC3C(window)
    window.mainloop()
