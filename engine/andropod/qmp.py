"""Minimal QMP client.

QMP is QEMU's documented JSON control protocol. We talk to it over a unix
socket. This module is the *only* thing in the project that knows about QEMU
internals, which is exactly what keeps the GPL boundary clean: nothing here
links against QEMU, we just speak its wire protocol.
"""

from __future__ import annotations

import json
import socket
import time
from pathlib import Path
from typing import Any, Callable


class QMPError(RuntimeError):
    pass


class QMPClient:
    def __init__(self, sock_path: Path, timeout: float = 15.0) -> None:
        self.sock_path = Path(sock_path)
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._file = None
        self._next_id = 0
        self._handlers: dict[str, list[Callable[[dict], None]]] = {}
        self.greeting: dict | None = None

    # -- lifecycle ---------------------------------------------------------

    def connect(self, wait: float = 20.0) -> None:
        """Wait for QEMU to create the socket, then complete the handshake."""
        deadline = time.monotonic() + wait
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            if self.sock_path.exists():
                try:
                    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    sock.settimeout(self.timeout)
                    sock.connect(str(self.sock_path))
                    self._sock = sock
                    self._file = sock.makefile("rwb")
                    self._read_greeting()
                    self.execute("qmp_capabilities")
                    return
                except OSError as exc:
                    last_error = exc
                    self.close()
            time.sleep(0.1)
        raise QMPError(f"无法连接 QMP socket {self.sock_path}: {last_error}")

    def close(self) -> None:
        for closable in (self._file, self._sock):
            try:
                if closable is not None:
                    closable.close()
            except Exception:
                pass
        self._file = None
        self._sock = None

    def __enter__(self) -> "QMPClient":
        self.connect()
        return self

    def __exit__(self, *exc_info) -> None:
        self.close()

    # -- commands ----------------------------------------------------------

    def execute(self, command: str, arguments: dict | None = None) -> Any:
        self._next_id += 1
        request_id = self._next_id
        message: dict[str, Any] = {"execute": command, "id": request_id}
        if arguments:
            message["arguments"] = arguments
        self._send(message)

        while True:
            reply = self._recv()
            if "event" in reply:
                self._dispatch(reply)
                continue
            if reply.get("id") != request_id:
                continue
            if "error" in reply:
                err = reply["error"]
                raise QMPError(
                    f"{err.get('class', 'GenericError')}: {err.get('desc', '')} "
                    f"(command={command})"
                )
            return reply.get("return")

    def hmp(self, command_line: str) -> str:
        """Run a human-monitor-command. Used for savevm/loadvm, which have no
        native QMP equivalent that carries full VM state."""
        result = self.execute("human-monitor-command", {"command-line": command_line})
        return result or ""

    def on_event(self, name: str, handler: Callable[[dict], None]) -> None:
        self._handlers.setdefault(name, []).append(handler)

    # -- transport ---------------------------------------------------------

    def _send(self, message: dict) -> None:
        if self._file is None:
            raise QMPError("QMP 连接未建立")
        try:
            self._file.write(json.dumps(message).encode() + b"\n")
            self._file.flush()
        except (BrokenPipeError, OSError) as exc:
            raise QMPError(f"写入 QMP 失败: {exc}") from exc

    def _recv(self) -> dict:
        if self._file is None:
            raise QMPError("QMP 连接未建立")
        try:
            line = self._file.readline()
        except socket.timeout as exc:
            raise QMPError("读取 QMP 超时") from exc
        if not line:
            raise QMPError("QMP 连接被关闭（QEMU 进程可能已退出）")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise QMPError(f"QMP 返回了非法 JSON: {line[:200]!r}") from exc

    def _read_greeting(self) -> None:
        greeting = self._recv()
        if "QMP" not in greeting:
            raise QMPError(f"非预期的 QMP 握手响应: {greeting}")
        self.greeting = greeting["QMP"]

    def _dispatch(self, event: dict) -> None:
        for handler in self._handlers.get(event.get("event", ""), []):
            try:
                handler(event.get("data", {}))
            except Exception:
                pass
