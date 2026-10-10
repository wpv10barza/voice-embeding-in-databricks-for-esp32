"""Record and inspect a Windows mic before calling Databricks Gemini.

  py scripts/Grabar-Microfono3C.py --list
  py scripts/Grabar-Microfono3C.py --device 1 --seconds 8 --output test.wav

A WAV file alone proves only that an input stream was read, NOT that the
correct microphone (or an intelligible maintenance command) was captured.
No credentials, outgoing network calls, or Google Sheets writes.
"""
from __future__ import annotations
import argparse
from array import array
from pathlib import Path
import math
import wave


def _get_audio_library():
    try:
        import sounddevice as sd
    except ImportError as exc:
        raise SystemExit(
            "Falta sounddevice. Instalar una vez: py -m pip install sounddevice"
        ) from exc
    return sd


def show_inputs(sd=None) -> list[int]:
    sd = sd or _get_audio_library()
    default = sd.default.device
    try:
        default_input = default[0]
    except (TypeError, IndexError):
        default_input = default
    available = []
    print("[MIC] Dispositivos de ENTRADA disponibles:")
    for i, entry in enumerate(sd.query_devices()):
        if int(entry.get("max_input_channels", 0)) <= 0:
            continue
        available.append(i)
        tag = " [PREDETERMINADO]" if i == default_input else ""
        name = str(entry.get("name", "Sin nombre"))
        if any(x in name.lower() for x in ("stereo mix", "mezcla est", "what u hear", "loopback")):
            tag += " [POSIBLE AUDIO DEL SISTEMA, NO MICROFONO]"
        print(f"  ID {i}: {name}{tag}")
    if not available:
        raise SystemExit("No existen dispositivos de entrada de audio habilitados.")
    return available


def _quality(pcm_bytes: bytes) -> tuple[float, float]:
    pcm = array("h")
    pcm.frombytes(pcm_bytes)
    if not pcm:
        raise SystemExit("La grabacion contiene cero muestras.")
    rms = math.sqrt(sum(int(sample) ** 2 for sample in pcm) / len(pcm)) / 32768.0
    peak = max(abs(int(sample)) for sample in pcm) / 32768.0
    return rms, peak


def record(seconds: int, target: Path, device: int | None = None) -> None:
    if not 1 <= seconds <= 25:
        raise ValueError("Recording must be 1-25 seconds (fits Databricks 1 MiB limit)")
    sd = _get_audio_library()
    if device is not None:
        info = sd.query_devices(device)
        if int(info.get("max_input_channels", 0)) < 1:
            raise SystemExit(f"ID {device} no es una entrada de audio.")
    else:
        try:
            default_input = sd.default.device[0]
            info = sd.query_devices(default_input)
        except Exception as exc:
            raise SystemExit(
                "Windows no tiene microfono predeterminado. Ejecuta --list y elige --device ID."
            ) from exc
    mic_name = str(info.get("name", "Desconocido"))
    print(f"[MIC] Fuente elegida: {mic_name}; ID={device if device is not None else default_input}", flush=True)
    if any(key in mic_name.lower() for key in ("stereo mix", "mezcla est", "what u hear", "loopback")):
        print("[ADVERTENCIA] Parece una fuente de audio del sistema, NO el microfono. Use --list y --device.", flush=True)
    samplerate = 16000
    try:
        sd.check_input_settings(device=device, channels=1, samplerate=samplerate)
        print(f"[MIC] Grabando {seconds}s a 16 kHz mono; hable una orden de mantenimiento...", flush=True)
        audio = sd.rec(seconds * samplerate, samplerate=samplerate, channels=1,
                       dtype="int16", device=device)
        sd.wait()
    except Exception as exc:
        raise SystemExit(
            f"Micrófono no disponible: {exc}. Comprueba permisos de Windows y --device."
        ) from exc
    pcm_bytes = audio.tobytes()
    rms, peak = _quality(pcm_bytes)
    print(f"[MIC] Nivel RMS: {rms:.3f} / pico: {peak:.3f}", flush=True)
    if rms < 0.003:
        print("[ADVERTENCIA] Entrada demasiado silenciosa: revise volumen, microfono seleccionado y permisos.", flush=True)
    if peak >= 0.985:
        print("[ADVERTENCIA] Audio saturado: reduzca la ganancia del microfono.", flush=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(target), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(samplerate)
        wav.writeframes(pcm_bytes)
    if target.stat().st_size > 1_048_576:
        target.unlink(missing_ok=True)
        raise SystemExit("WAV supera 1 MiB y no se enviara a Databricks.")
    print(f"[MIC] WAV listo: {target.stat().st_size} bytes", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="Lista microfonos de entrada y su ID.")
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--device", type=int)
    args = parser.parse_args()
    if args.list:
        show_inputs()
        return
    if args.output is None:
        parser.error("--output es obligatorio al grabar.")
    record(args.seconds, args.output, args.device)


if __name__ == "__main__":
    main()
