"""
HTTP client for Zypi container runtime — Agent Fabric Edition.

Supports one-shot exec, long-lived sessions, streaming output,
image pre-warming, and fabric memory integration with MosaicDB.
"""
import requests
import json
import time
from typing import Optional, Dict, List, Tuple, Iterator, Any
from dataclasses import dataclass, field


@dataclass
class ExecResult:
    exit_code: int
    stdout: str
    stderr: str
    duration_ms: int = 0
    container_id: str = ""
    agent_id: Optional[str] = None
    timed_out: bool = False

    @classmethod
    def from_response(cls, data: dict) -> "ExecResult":
        return cls(
            exit_code=data.get("exit_code", -1),
            stdout=data.get("stdout", ""),
            stderr=data.get("stderr", ""),
            duration_ms=data.get("duration_ms", 0),
            container_id=data.get("container_id", ""),
            agent_id=data.get("agent_id"),
            timed_out=data.get("timed_out", False),
        )


@dataclass
class Session:
    session_id: str
    container_id: str
    ip: str
    image: str
    agent_id: Optional[str] = None
    status: str = "running"
    created_at: str = ""

    @classmethod
    def from_response(cls, data: dict) -> "Session":
        return cls(
            session_id=data.get("session_id", ""),
            container_id=data.get("container_id", ""),
            ip=data.get("ip", ""),
            image=data.get("image", ""),
            agent_id=data.get("agent_id"),
            status=data.get("status", "running"),
            created_at=data.get("created_at", ""),
        )


@dataclass
class ZypiClient:
    """HTTP client for Zypi agent sandbox runtime."""

    base_url: str = "http://localhost:4000"
    default_image: str = "ubuntu:24.04"
    timeout: int = 300

    # ── Health ──────────────────────────────────────────────

    def health_check(self) -> bool:
        """Check if Zypi is running."""
        try:
            r = requests.get(f"{self.base_url}/health", timeout=5)
            return r.status_code == 200
        except Exception:
            return False

    # ── One-Shot Execution ──────────────────────────────────

    def exec(
        self,
        cmd: List[str],
        image: Optional[str] = None,
        env: Optional[Dict[str, str]] = None,
        workdir: Optional[str] = None,
        files: Optional[Dict[str, str]] = None,
        agent_id: Optional[str] = None,
        timeout: Optional[int] = None,
    ) -> ExecResult:
        """Execute a command in a one-shot sandbox. VM is destroyed after."""
        payload = {
            "cmd": cmd,
            "image": image or self.default_image,
        }
        if env:
            payload["env"] = env
        if workdir:
            payload["workdir"] = workdir
        if files:
            payload["files"] = files
        if agent_id:
            payload["agent_id"] = agent_id
        if timeout:
            payload["timeout"] = timeout

        response = requests.post(
            f"{self.base_url}/exec",
            json=payload,
            timeout=timeout or self.timeout,
        )
        response.raise_for_status()
        return ExecResult.from_response(response.json())

    def exec_streaming(
        self,
        cmd: List[str],
        image: Optional[str] = None,
        agent_id: Optional[str] = None,
        env: Optional[Dict[str, str]] = None,
        workdir: Optional[str] = None,
        timeout: Optional[int] = None,
    ) -> Iterator[dict]:
        """Execute a command with SSE streaming output.

        Yields events: {"event": "result"|"error"|"done", "data": ...}
        """
        payload = {
            "cmd": cmd,
            "image": image or self.default_image,
            "stream": True,
        }
        if env:
            payload["env"] = env
        if workdir:
            payload["workdir"] = workdir
        if agent_id:
            payload["agent_id"] = agent_id
        if timeout:
            payload["timeout"] = timeout

        response = requests.post(
            f"{self.base_url}/exec",
            json=payload,
            stream=True,
            timeout=timeout or self.timeout,
        )
        response.raise_for_status()

        for line in response.iter_lines(decode_unicode=True):
            if not line:
                continue
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: "):
                data = line[6:]
                try:
                    data = json.loads(data)
                except (json.JSONDecodeError, TypeError):
                    pass
                yield {"event": event, "data": data}

    # ── Sessions ────────────────────────────────────────────

    def session_create(
        self,
        image: Optional[str] = None,
        agent_id: Optional[str] = None,
        vcpus: int = 1,
        memory_mb: int = 256,
    ) -> Session:
        """Create a long-lived sandbox session. VM stays alive between execs."""
        payload = {
            "image": image or self.default_image,
            "agent_id": agent_id,
            "vcpus": vcpus,
            "memory_mb": memory_mb,
        }
        payload = {k: v for k, v in payload.items() if v is not None}

        response = requests.post(
            f"{self.base_url}/sessions",
            json=payload,
            timeout=30,
        )
        response.raise_for_status()
        return Session.from_response(response.json())

    def session_exec(
        self,
        session_id: str,
        cmd: List[str],
        env: Optional[Dict[str, str]] = None,
        workdir: Optional[str] = None,
        timeout: int = 30,
    ) -> ExecResult:
        """Execute a command in an existing session."""
        payload = {
            "cmd": cmd,
            "env": env or {},
            "workdir": workdir,
            "timeout": timeout,
        }
        payload = {k: v for k, v in payload.items() if v is not None}

        response = requests.post(
            f"{self.base_url}/sessions/{session_id}/exec",
            json=payload,
            timeout=timeout + 10,
        )
        response.raise_for_status()
        return ExecResult.from_response(response.json())

    def session_exec_streaming(
        self,
        session_id: str,
        cmd: List[str],
        env: Optional[Dict[str, str]] = None,
        workdir: Optional[str] = None,
        timeout: int = 30,
    ) -> Iterator[dict]:
        """Execute in a session with SSE streaming."""
        payload = {
            "cmd": cmd,
            "stream": True,
            "env": env or {},
            "workdir": workdir,
            "timeout": timeout,
        }
        payload = {k: v for k, v in payload.items() if v is not None}

        response = requests.post(
            f"{self.base_url}/sessions/{session_id}/exec",
            json=payload,
            stream=True,
            timeout=timeout + 10,
        )
        response.raise_for_status()

        for line in response.iter_lines(decode_unicode=True):
            if not line:
                continue
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: "):
                data = line[6:]
                try:
                    data = json.loads(data)
                except (json.JSONDecodeError, TypeError):
                    pass
                yield {"event": event, "data": data}

    def session_get(self, session_id: str) -> Session:
        """Get session details."""
        response = requests.get(
            f"{self.base_url}/sessions/{session_id}",
            timeout=5,
        )
        response.raise_for_status()
        return Session.from_response(response.json())

    def session_list(self) -> List[dict]:
        """List all active sessions."""
        response = requests.get(f"{self.base_url}/sessions", timeout=5)
        response.raise_for_status()
        return response.json().get("sessions", [])

    def session_close(self, session_id: str) -> bool:
        """Close and destroy a session."""
        response = requests.delete(
            f"{self.base_url}/sessions/{session_id}",
            timeout=10,
        )
        return response.status_code == 200

    # ── Image Warm ──────────────────────────────────────────

    def warm_image(self, image_ref: str, count: int = 1) -> dict:
        """Request pre-warming of VMs for an image."""
        response = requests.post(
            f"{self.base_url}/images/{image_ref}/warm",
            json={"count": min(count, 10)},
            timeout=5,
        )
        response.raise_for_status()
        return response.json()

    def warm_status(self, image_ref: str) -> dict:
        """Check warm VM count for an image."""
        response = requests.get(
            f"{self.base_url}/images/{image_ref}/warm-status",
            timeout=5,
        )
        response.raise_for_status()
        return response.json()

    # ── Pool ────────────────────────────────────────────────

    def pool_stats(self) -> dict:
        """Get VM pool statistics."""
        response = requests.get(f"{self.base_url}/pool/stats", timeout=5)
        response.raise_for_status()
        return response.json()

    def session_stats(self) -> dict:
        """Get session statistics."""
        response = requests.get(f"{self.base_url}/sessions/stats", timeout=5)
        response.raise_for_status()
        return response.json()

    # ── Convenience ─────────────────────────────────────────

    def shell(self, command: str, image: Optional[str] = None, **kwargs) -> ExecResult:
        """Run a shell command (convenience wrapper)."""
        return self.exec(["/bin/sh", "-c", command], image=image, **kwargs)

    def run_python(
        self,
        code: str,
        image: str = "python:3.12-slim",
        agent_id: Optional[str] = None,
        **kwargs,
    ) -> ExecResult:
        """Run Python code in a sandbox."""
        files = kwargs.pop("files", {})
        files["/script/run.py"] = code
        return self.exec(
            ["python", "/script/run.py"],
            image=image,
            agent_id=agent_id,
            files=files,
            **kwargs,
        )
