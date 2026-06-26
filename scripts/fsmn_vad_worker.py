#!/usr/bin/env python3
"""Streaming FSMN-VAD worker for Doubao Voice CLI.

Reads 16 kHz mono signed-int16 PCM from stdin in configurable chunks and writes
JSON events to stdout. The macOS helper owns microphone capture and shortcut
triggering; this process owns the FunASR FSMN-VAD model.

When launched with ``--serve <socket_path>``, it runs as a persistent daemon:
the model is loaded once, and the worker accepts one client at a time over a
Unix Domain Socket.  Each connection is an independent VAD session.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sys
import traceback
import contextlib
import warnings


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(minimum, min(maximum, value))


SAMPLE_RATE = 16000
# FSMN-VAD still expects 16 kHz audio.  This value controls how often we call
# model.generate(). Local benchmarks show 300 ms chunks cost only about 7 ms
# per inference on the target Mac, so this improves endpointing latency without
# creating model backlog.
CHUNK_MS = _env_int("DOUBAO_VOICE_FSMN_CHUNK_MS", 300, 100, 2000)
SAMPLES_PER_CHUNK = SAMPLE_RATE * CHUNK_MS // 1000
BYTES_PER_CHUNK = SAMPLES_PER_CHUNK * 2
MODELSCOPE_FSMN_MODEL_RELATIVE_PATH = (
    "models/iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
)


def emit(event: str, **payload: object) -> None:
    payload["event"] = event
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def emit_to(conn: socket.socket, event: str, **payload: object) -> bool:
    """Write a JSON event line to *conn*.  Returns False on broken pipe."""
    payload["event"] = event
    line = json.dumps(payload, ensure_ascii=False) + "\n"
    try:
        conn.sendall(line.encode("utf-8"))
        return True
    except OSError:
        return False


def default_model_name() -> str:
    """Prefer the model bundled beside the CLI before using the hub alias."""
    cache_dir = os.environ.get("MODELSCOPE_CACHE")
    if cache_dir:
        local_model = os.path.join(cache_dir, MODELSCOPE_FSMN_MODEL_RELATIVE_PATH)
        if (
            os.path.exists(os.path.join(local_model, "config.yaml"))
            and os.path.exists(os.path.join(local_model, "model.pt"))
        ):
            return local_model
    return "fsmn-vad"


def _recv_exactly(conn: socket.socket, n: int) -> bytes:
    """Read exactly *n* bytes from *conn*, or return short/empty on EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
    return bytes(buf)


def load_model():
    """Load dependencies and the FSMN-VAD model.  Returns (model, np) or raises."""
    warnings.filterwarnings("ignore", message="urllib3 v2 only supports OpenSSL.*")
    with open(os.devnull, "w", encoding="utf-8") as devnull, \
         contextlib.redirect_stdout(devnull), contextlib.redirect_stderr(devnull):
        import numpy as np
        from funasr import AutoModel

    model_name = os.environ.get("DOUBAO_VOICE_FSMN_MODEL") or default_model_name()
    model_revision = os.environ.get("DOUBAO_VOICE_FSMN_REVISION", "v2.0.4")

    try:
        with open(os.devnull, "w", encoding="utf-8") as devnull, \
             contextlib.redirect_stdout(devnull), contextlib.redirect_stderr(devnull):
            model = AutoModel(
                model=model_name,
                model_revision=model_revision,
                device="cpu",
                disable_update=True,
                disable_pbar=True,
                check_latest=False,
                log_level="ERROR",
            )
    except TypeError:
        with open(os.devnull, "w", encoding="utf-8") as devnull, \
             contextlib.redirect_stdout(devnull), contextlib.redirect_stderr(devnull):
            model = AutoModel(
                model=model_name,
                device="cpu",
                disable_update=True,
                disable_pbar=True,
                log_level="ERROR",
            )

    return model, np, model_name, model_revision


def run_session_stdin(model, np) -> int:
    """Original stdin/stdout single-session mode."""
    max_end_silence_ms = int(os.environ.get("DOUBAO_VOICE_FSMN_END_SILENCE_MS", "800"))

    cache: dict = {}
    absolute_ms = 0
    stdin = sys.stdin.buffer

    while True:
        chunk = stdin.read(BYTES_PER_CHUNK)
        if not chunk:
            break
        if len(chunk) < BYTES_PER_CHUNK:
            chunk = chunk + (b"\x00" * (BYTES_PER_CHUNK - len(chunk)))

        speech = np.frombuffer(chunk, dtype=np.int16).astype("float32") / 32768.0
        try:
            result = model.generate(
                input=speech,
                cache=cache,
                is_final=False,
                chunk_size=CHUNK_MS,
                max_end_silence_time=max_end_silence_ms,
                disable_pbar=True,
            )
        except Exception as exc:
            emit("error", code="generate_failed", message=str(exc), traceback=traceback.format_exc())
            return 4

        values = []
        if result and isinstance(result, list):
            first = result[0]
            if isinstance(first, dict):
                values = first.get("value") or []

        for item in values:
            if not isinstance(item, (list, tuple)) or len(item) < 2:
                continue
            beg_ms = int(item[0])
            end_ms = int(item[1])
            if beg_ms != -1:
                emit("speech_start", at_ms=beg_ms)
            if end_ms != -1:
                emit("speech_end", at_ms=end_ms)

        absolute_ms += CHUNK_MS
        emit("progress", elapsed_ms=absolute_ms)

    emit("eof")
    return 0


def handle_session(conn: socket.socket, model, np) -> None:
    """Handle a single VAD session over an accepted socket connection.

    Protocol (binary, newline-delimited JSON responses):
      1. Client sends raw PCM16 data in streaming fashion.
      2. Server reads in BYTES_PER_CHUNK increments and runs VAD.
      3. Server writes back JSON event lines (speech_start, speech_end,
         progress, error, session_end).
      4. When the client closes its write side (EOF), the session ends.
    """
    max_end_silence_ms = int(os.environ.get("DOUBAO_VOICE_FSMN_END_SILENCE_MS", "800"))

    # Send session_start so the client knows the session is live.
    if not emit_to(conn, "session_start"):
        return

    cache: dict = {}
    absolute_ms = 0

    while True:
        chunk = _recv_exactly(conn, BYTES_PER_CHUNK)
        if not chunk:
            break
        if len(chunk) < BYTES_PER_CHUNK:
            chunk = chunk + (b"\x00" * (BYTES_PER_CHUNK - len(chunk)))

        speech = np.frombuffer(chunk, dtype=np.int16).astype("float32") / 32768.0
        try:
            result = model.generate(
                input=speech,
                cache=cache,
                is_final=False,
                chunk_size=CHUNK_MS,
                max_end_silence_time=max_end_silence_ms,
                disable_pbar=True,
            )
        except Exception as exc:
            emit_to(conn, "error", code="generate_failed", message=str(exc),
                    traceback=traceback.format_exc())
            break

        values = []
        if result and isinstance(result, list):
            first = result[0]
            if isinstance(first, dict):
                values = first.get("value") or []

        for item in values:
            if not isinstance(item, (list, tuple)) or len(item) < 2:
                continue
            beg_ms = int(item[0])
            end_ms = int(item[1])
            if beg_ms != -1:
                if not emit_to(conn, "speech_start", at_ms=beg_ms):
                    return
            if end_ms != -1:
                if not emit_to(conn, "speech_end", at_ms=end_ms):
                    return

        absolute_ms += CHUNK_MS
        if not emit_to(conn, "progress", elapsed_ms=absolute_ms):
            break

    emit_to(conn, "session_end")


def serve_socket(socket_path: str, model, np, model_name: str,
                 model_revision: str) -> int:
    """Run as a persistent Unix Domain Socket server."""
    max_end_silence_ms = int(os.environ.get("DOUBAO_VOICE_FSMN_END_SILENCE_MS", "800"))

    # Clean up stale socket file.
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    # Make sure parent directory exists.
    os.makedirs(os.path.dirname(socket_path), exist_ok=True)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(1)

    # Register cleanup for SIGTERM.
    def _cleanup(signum, frame):
        try:
            server.close()
        except OSError:
            pass
        try:
            os.unlink(socket_path)
        except OSError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)

    # Tell the parent (ObjC helper) that the model is loaded and the socket
    # is ready to accept connections.
    emit(
        "ready",
        model=model_name,
        model_revision=model_revision,
        chunk_ms=CHUNK_MS,
        sample_rate=SAMPLE_RATE,
        max_end_silence_ms=max_end_silence_ms,
        socket=socket_path,
    )

    try:
        while True:
            conn, _ = server.accept()
            try:
                handle_session(conn, model, np)
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass
    except OSError:
        # Server socket was closed (SIGTERM path or shutdown).
        pass
    finally:
        try:
            os.unlink(socket_path)
        except OSError:
            pass

    return 0


def main() -> int:
    # Parse --serve argument.
    socket_path: str | None = None
    if "--serve" in sys.argv:
        idx = sys.argv.index("--serve")
        if idx + 1 < len(sys.argv):
            socket_path = sys.argv[idx + 1]
        else:
            print("Usage: fsmn_vad_worker.py --serve <socket_path>", file=sys.stderr)
            return 1

    # Load dependencies.
    try:
        model, np, model_name, model_revision = load_model()
    except ImportError as exc:
        emit(
            "error",
            code="missing_dependency",
            message=(
                "Python dependencies are missing. Install with: "
                "python3 -m pip install --user -U torch torchaudio funasr modelscope"
            ),
            detail=repr(exc),
        )
        return 2
    except Exception as exc:
        emit("error", code="model_load_failed", message=str(exc),
             traceback=traceback.format_exc())
        return 3

    if socket_path is not None:
        return serve_socket(socket_path, model, np, model_name, model_revision)

    # Original stdin mode.
    max_end_silence_ms = int(os.environ.get("DOUBAO_VOICE_FSMN_END_SILENCE_MS", "800"))
    emit(
        "ready",
        model=model_name,
        model_revision=model_revision,
        chunk_ms=CHUNK_MS,
        sample_rate=SAMPLE_RATE,
        max_end_silence_ms=max_end_silence_ms,
    )
    return run_session_stdin(model, np)


if __name__ == "__main__":
    raise SystemExit(main())
