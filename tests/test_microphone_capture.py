"""Hardware-free capture regression for the Databricks voice pipeline."""
from __future__ import annotations
import importlib.util
import sys
import tempfile
import types
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[1]
modpath = root / "scripts" / "Grabar-Microfono3C.py"
spec = importlib.util.spec_from_file_location("microphone_recorder", modpath)
assert spec and spec.loader
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)

class FakeAudio:
    def __init__(self, frames):
        self.frames = frames
    def tobytes(self):
        return b"\x00\x00" * self.frames

def fake_rec(frames, *, samplerate, channels, dtype, device):
    assert samplerate == 16000 and channels == 1 and dtype == "int16"
    assert frames == 3 * 16000
    return FakeAudio(frames)

fake_sd = types.SimpleNamespace(
    check_input_settings=lambda **kwargs: None,
    rec=fake_rec,
    wait=lambda: None,
)
sys.modules["sounddevice"] = fake_sd
try:
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "voice.wav"
        recorder.record(3, target)
        with wave.open(str(target), "rb") as wav:
            assert wav.getframerate() == 16000
            assert wav.getnchannels() == 1
            assert wav.getsampwidth() == 2
            assert wav.getnframes() == 48000
        assert target.stat().st_size < 1_048_576
        try:
            recorder.record(50, target)
            raise AssertionError("Recording over 25s must be rejected")
        except ValueError:
            pass
finally:
    sys.modules.pop("sounddevice", None)
print("Microphone WAV recording contract: PASS")
