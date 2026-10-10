"""Offline-only mic selection/recording checks with a simulated audio device."""
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
    def __init__(self, frames, amplitude=1400):
        self.frames = frames
        self.amplitude = amplitude
    def tobytes(self):
        return int(self.amplitude).to_bytes(2, "little", signed=True) * self.frames

class FakeSd:
    def __init__(self):
        self.default = types.SimpleNamespace(device=(1, 2))
        self.recorded_device = None
    def query_devices(self, device=None):
        devices = [
            {"name": "Stereo Mix (audio del sistema)", "max_input_channels": 2},
            {"name": "Microfono USB", "max_input_channels": 1},
            {"name": "Altavoces", "max_input_channels": 0},
        ]
        return devices if device is None else devices[device]
    def check_input_settings(self, **kwargs):
        pass
    def rec(self, frames, *, samplerate, channels, dtype, device):
        assert samplerate == 16000 and channels == 1 and dtype == "int16"
        assert frames == 3 * 16000
        self.recorded_device = device
        return FakeAudio(frames)
    def wait(self):
        pass

fake_sd = FakeSd()
sys.modules["sounddevice"] = fake_sd
try:
    assert recorder.show_inputs(fake_sd) == [0, 1]
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "voice.wav"
        recorder.record(3, target, device=1)
        assert fake_sd.recorded_device == 1
        with wave.open(str(target), "rb") as wav:
            assert wav.getframerate() == 16000
            assert wav.getnchannels() == 1
            assert wav.getsampwidth() == 2
            assert wav.getnframes() == 48000
        assert target.stat().st_size < 1_048_576
        assert recorder._quality(FakeAudio(100, amplitude=1400).tobytes())[0] > 0.01
        try:
            recorder.record(50, target)
            raise AssertionError("Audio over 25 seconds must be rejected")
        except ValueError:
            pass
        try:
            recorder.record(3, target, device=2)
            raise AssertionError("Speaker must not be accepted as microphone")
        except SystemExit:
            pass
finally:
    sys.modules.pop("sounddevice", None)
print("Microphone input selection, RMS, and WAV capture contract: PASS")
