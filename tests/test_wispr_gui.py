"""Contract test for a desktop-only Wispr Flow bridge (no microphones/network/UI)."""
from __future__ import annotations
import ast
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "scripts/DictarPC3C-Wispr.py"
source = path.read_text(encoding="utf-8")
ast.parse(source)
spec = importlib.util.spec_from_file_location("dictar_pc_3c_wispr", path)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.normalize_draft("  Cambia\n lubricación  a trimestral ") == (
    "Cambia lubricación a trimestral"
)
try:
    module.normalize_draft("")
except ValueError:
    pass
else:
    raise AssertionError("Empty Wispr dictation must not submit")
try:
    module.normalize_draft("ñ" * 116)
except ValueError:
    pass
else:
    raise AssertionError("230 UTF-8 byte limit must reject oversized content")

assert 'GEMINI_API_KEY' not in source
assert "/voice/transcribe" not in source
assert "/api/apply" not in source
assert "/api/device/v1/commands" not in source
assert "clipboard_get(" not in source
assert "pynput" not in source
assert "keyboard.hook" not in source
assert "voice/drafts" in source
assert "delivered_to_editor" in source
assert "QUIET_SECONDS" in source
assert "self.active" in source
assert "self.device_token = \"\"" in source
assert "ESP32_API_TOKEN" in source
assert "http" in source and "databricks" in source
assert "manual" in source.lower()
for launcher in ("ABRIR-DICTAR-PC-3C.vbs", "ABRIR-DICTAR-PC-3C.cmd"):
    assert (root / "scripts" / launcher).exists()
print("Wispr Flow GUI: no Gemini, no microphone recording, no clipboard spy, "
      "human final approval, valid UTF-8 text, and safe on/off contract: PASS")
