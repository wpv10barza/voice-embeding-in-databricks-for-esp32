"""Record a short Windows microphone clip to WAV for Databricks Gemini STT.

Requires: py -m pip install sounddevice
Uses the default recording device, 16-kHz signed 16-bit mono PCM, <1 MiB.
Does not store credentials or make network calls.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import wave

def record(seconds: int, target: Path, device: int | None = None) -> None:
    if not 1 <= seconds <= 25:
        raise ValueError("Recording must be 1-25 seconds (fits Databricks 1 MiB limit)")
    try:
        import sounddevice as sd
    except ImportError as exc:
        raise SystemExit(
            "Falta sounddevice. Instalar UNA VEZ: py -m pip install sounddevice"
        ) from exc

    samplerate = 16000
    try:
        sd.check_input_settings(device=device, channels=1, samplerate=samplerate)
        print(f"[MIC] Grabando {seconds}s a 16 kHz mono; hable ahora...", flush=True)
        audio = sd.rec(seconds * samplerate, samplerate=samplerate, channels=1,
                       dtype="int16", device=device)
        sd.wait()
    except Exception as exc:
        raise SystemExit(
            f"Micrófono no disponible: {exc}. Compruebe permisos de Windows y el dispositivo predeterminado."
        ) from exc
    target.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(target), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(samplerate)
        wav.writeframes(audio.tobytes())
    print(f"[MIC] WAV listo: {target.stat().st_size} bytes", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", type=int)
    args = parser.parse_args()
    record(args.seconds, args.output, args.device)


if __name__ == "__main__":
    main()
