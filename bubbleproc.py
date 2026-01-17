"""
Python wrapper that executes commands in Zypi Firecracker VMs.
"""

from __future__ import annotations

import io
import os
import subprocess
from dataclasses import dataclass, field
from typing import Any, Optional, List, Dict, Union, Sequence, Mapping, IO, Tuple

try:
    from zypi_client import ZypiClient
except ImportError:
    ZypiClient = None


__all__ = [
    "Sandbox",
    "run",
    "patch_subprocess",
    "unpatch_subprocess",
    "SandboxError",
    "SandboxedPopen",
]

# =============================================================================
# CONSTANTS
# =============================================================================

ESSENTIAL_ENV_VARS = [
    "PATH",
    "HOME",
    "USER",
    "SHELL",
    "TERM",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TMPDIR",
    "TEMP",
    "TMP",
]

DEFAULT_ENV_PASSTHROUGH = ESSENTIAL_ENV_VARS + [
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "GOOGLE_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL",
    "COLORTERM",
]


class SandboxError(Exception):
    """Raised when sandbox cannot be configured or executed."""
    pass


# =============================================================================
# SANDBOX CLASS
# =============================================================================

@dataclass
class Sandbox:
    """Sandbox that executes commands in Zypi Firecracker VMs."""
    
    zypi_url: str = "http://localhost:4000"
    image: str = "ubuntu:24.04"
    env: Dict[str, str] = field(default_factory=dict)
    env_passthrough: List[str] = field(default_factory=list)
    cwd: Optional[str] = None
    timeout: Optional[float] = None
    files: Dict[str, str] = field(default_factory=dict)
    
    # Legacy fields (ignored, kept for API compat)
    ro: List[str] = field(default_factory=list)
    rw: List[str] = field(default_factory=list)
    network: bool = False
    gpu: bool = False
    share_home: bool = False
    allow_secrets: List[str] = field(default_factory=list)
    
    _client: Any = field(init=False, repr=False, default=None)
    
    def __post_init__(self):
        if ZypiClient is None:
            raise SandboxError(
                "zypi_client module not found. Ensure zypi_client.py is in your path."
            )
        self._client = ZypiClient(
            base_url=self.zypi_url,
            default_image=self.image,
            timeout=int(self.timeout) if self.timeout else 300,
        )
        
        if not self._client.health_check():
            raise SandboxError(
                f"Zypi not reachable at {self.zypi_url}. "
                "Start Zypi with: mix phx.server"
            )
    
    def run(
        self,
        command_str: str,
        *,
        capture_output: bool = False,
        text: bool = True,
        check: bool = False,
        timeout: Optional[float] = None,
        **kwargs: Any,
    ) -> subprocess.CompletedProcess:
        """Run a command string in a Zypi container."""
        
        # Build environment from passthrough + explicit env
        exec_env = {}
        for var in self.env_passthrough:
            if var in os.environ:
                exec_env[var] = os.environ[var]
        exec_env.update(self.env)
        
        cmd = ["/bin/sh", "-c", command_str]
        
        try:
            exit_code, stdout, stderr = self._client.exec(
                cmd=cmd,
                env=exec_env if exec_env else None,
                workdir=self.cwd,
                files=self.files if self.files else None,
                timeout=int(timeout) if timeout else None,
            )
        except Exception as e:
            raise SandboxError(f"Zypi execution failed: {e}") from e
        
        if text:
            stdout_result = stdout if capture_output else ""
            stderr_result = stderr if capture_output else ""
        else:
            stdout_result = stdout.encode() if capture_output else b""
            stderr_result = stderr.encode() if capture_output else b""
        
        result = subprocess.CompletedProcess(
            args=[command_str],
            returncode=exit_code,
            stdout=stdout_result,
            stderr=stderr_result,
        )
        
        if check and exit_code != 0:
            raise subprocess.CalledProcessError(
                exit_code, command_str,
                output=result.stdout,
                stderr=result.stderr
            )
        
        return result


# =============================================================================
# CONVENIENCE FUNCTION
# =============================================================================

def run(command: str, **kwargs: Any) -> subprocess.CompletedProcess:
    """Convenience function for running a quick sandboxed command."""
    sandbox_keys = set(Sandbox.__dataclass_fields__.keys())
    sandbox_kwargs = {k: v for k, v in kwargs.items() if k in sandbox_keys}
    run_kwargs = {k: v for k, v in kwargs.items() if k not in sandbox_keys}
    sb = Sandbox(**sandbox_kwargs)
    return sb.run(command, **run_kwargs)


# =============================================================================
# MONKEY-PATCHING STATE
# =============================================================================

_patched = False
_patch_config: Dict[str, Any] = {}
_originals: Dict[str, Any] = {}


def _create_sandbox_from_config(cwd: Optional[str] = None) -> Sandbox:
    """Create Sandbox from patch config."""
    env_passthrough = list(_patch_config.get("env_passthrough", DEFAULT_ENV_PASSTHROUGH))
    
    for var in ESSENTIAL_ENV_VARS:
        if var not in env_passthrough:
            env_passthrough.append(var)
    
    return Sandbox(
        zypi_url=_patch_config.get("zypi_url", "http://localhost:4000"),
        image=_patch_config.get("image", "ubuntu:24.04"),
        env_passthrough=env_passthrough,
        cwd=cwd,
        network=_patch_config.get("network", False),
    )


# =============================================================================
# SANDBOXED POPEN
# =============================================================================

class SandboxedPopen(subprocess.Popen):
    """Sandboxed Popen using Zypi containers."""
    
    _sandboxed_result: Optional[subprocess.CompletedProcess] = None
    
    def __init__(self, args, shell=False, env=None, cwd=None,
                 stdout=None, stderr=None, text=False, **kwargs):
        
        if shell and isinstance(args, str) and env is None:
            sb = _create_sandbox_from_config(cwd=str(cwd) if cwd else None)
            
            try:
                self._sandboxed_result = sb.run(
                    args,
                    capture_output=True,
                    text=text,
                    check=False,
                )
                self.returncode = self._sandboxed_result.returncode
            except SandboxError:
                self.returncode = 127
                self._sandboxed_result = subprocess.CompletedProcess(
                    args=[args], returncode=127, stdout=b"", stderr=b"Sandbox failed"
                )
            
            self.stdout = io.BytesIO(
                self._sandboxed_result.stdout.encode()
                if isinstance(self._sandboxed_result.stdout, str)
                else self._sandboxed_result.stdout or b""
            ) if stdout == subprocess.PIPE else None
            
            self.stderr = io.BytesIO(
                self._sandboxed_result.stderr.encode()
                if isinstance(self._sandboxed_result.stderr, str)
                else self._sandboxed_result.stderr or b""
            ) if stderr == subprocess.PIPE else None
            
            self.pid = 0
        else:
            super().__init__(args, shell=shell, env=env, cwd=cwd,
                             stdout=stdout, stderr=stderr, text=text, **kwargs)
    
    def poll(self):
        return self.returncode if self._sandboxed_result else super().poll()
    
    def wait(self, timeout=None):
        return self.returncode if self._sandboxed_result else super().wait(timeout)
    
    def communicate(self, input=None, timeout=None):
        if self._sandboxed_result:
            stdout = self._sandboxed_result.stdout or ""
            stderr = self._sandboxed_result.stderr or ""
            if isinstance(stdout, str):
                stdout = stdout.encode()
            if isinstance(stderr, str):
                stderr = stderr.encode()
            return stdout, stderr
        return super().communicate(input, timeout)


# =============================================================================
# SANDBOXED SUBPROCESS FUNCTIONS
# =============================================================================

def _create_sandboxed_run():
    """Create a sandboxed version of subprocess.run."""
    original_run = _originals["run"]

    def sandboxed_run(
        args: Union[str, Sequence[str]],
        *,
        bufsize: int = -1,
        executable: Optional[str] = None,
        stdin: Optional[Union[int, IO]] = None,
        stdout: Optional[Union[int, IO]] = None,
        stderr: Optional[Union[int, IO]] = None,
        preexec_fn: Optional[Any] = None,
        close_fds: bool = True,
        shell: bool = False,
        cwd: Optional[str] = None,
        env: Optional[Mapping[str, str]] = None,
        universal_newlines: Optional[bool] = None,
        startupinfo: Optional[Any] = None,
        creationflags: int = 0,
        restore_signals: bool = True,
        start_new_session: bool = False,
        pass_fds: Sequence[int] = (),
        capture_output: bool = False,
        timeout: Optional[float] = None,
        check: bool = False,
        text: bool = False,
        encoding: Optional[str] = None,
        errors: Optional[str] = None,
    ) -> subprocess.CompletedProcess:
        
        if shell and isinstance(args, str) and env is None:
            sb = _create_sandbox_from_config(cwd=str(cwd) if cwd else None)
            try:
                return sb.run(
                    args,
                    capture_output=capture_output or (stdout == subprocess.PIPE) or (stderr == subprocess.PIPE),
                    text=text or (encoding is not None) or (universal_newlines is True),
                    check=check,
                    timeout=timeout,
                )
            except SandboxError as e:
                if check:
                    raise subprocess.CalledProcessError(1, args, stderr=str(e).encode())
                return subprocess.CompletedProcess(
                    args=[args], returncode=1, stdout=b"", stderr=str(e).encode()
                )

        return original_run(
            args,
            bufsize=bufsize,
            executable=executable,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            preexec_fn=preexec_fn,
            close_fds=close_fds,
            shell=shell,
            cwd=cwd,
            env=env,
            universal_newlines=universal_newlines,
            startupinfo=startupinfo,
            creationflags=creationflags,
            restore_signals=restore_signals,
            start_new_session=start_new_session,
            pass_fds=pass_fds,
            capture_output=capture_output,
            timeout=timeout,
            check=check,
            text=text,
            encoding=encoding,
            errors=errors,
        )

    return sandboxed_run


def _create_sandboxed_call():
    """Create a sandboxed version of subprocess.call."""
    original_call = _originals["call"]

    def sandboxed_call(
        args: Union[str, Sequence[str]],
        *,
        bufsize: int = -1,
        executable: Optional[str] = None,
        stdin: Optional[Union[int, IO]] = None,
        stdout: Optional[Union[int, IO]] = None,
        stderr: Optional[Union[int, IO]] = None,
        preexec_fn: Optional[Any] = None,
        close_fds: bool = True,
        shell: bool = False,
        cwd: Optional[str] = None,
        env: Optional[Mapping[str, str]] = None,
        universal_newlines: Optional[bool] = None,
        startupinfo: Optional[Any] = None,
        creationflags: int = 0,
        restore_signals: bool = True,
        start_new_session: bool = False,
        pass_fds: Sequence[int] = (),
        timeout: Optional[float] = None,
    ) -> int:
        
        if shell and isinstance(args, str) and env is None:
            sb = _create_sandbox_from_config(cwd=str(cwd) if cwd else None)
            try:
                result = sb.run(args, check=False, timeout=timeout)
                return result.returncode
            except SandboxError:
                return 1

        return original_call(
            args,
            bufsize=bufsize,
            executable=executable,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            preexec_fn=preexec_fn,
            close_fds=close_fds,
            shell=shell,
            cwd=cwd,
            env=env,
            universal_newlines=universal_newlines,
            startupinfo=startupinfo,
            creationflags=creationflags,
            restore_signals=restore_signals,
            start_new_session=start_new_session,
            pass_fds=pass_fds,
            timeout=timeout,
        )

    return sandboxed_call


def _create_sandboxed_check_call():
    """Create a sandboxed version of subprocess.check_call."""
    original_check_call = _originals["check_call"]

    def sandboxed_check_call(
        args: Union[str, Sequence[str]],
        *,
        bufsize: int = -1,
        executable: Optional[str] = None,
        stdin: Optional[Union[int, IO]] = None,
        stdout: Optional[Union[int, IO]] = None,
        stderr: Optional[Union[int, IO]] = None,
        preexec_fn: Optional[Any] = None,
        close_fds: bool = True,
        shell: bool = False,
        cwd: Optional[str] = None,
        env: Optional[Mapping[str, str]] = None,
        universal_newlines: Optional[bool] = None,
        startupinfo: Optional[Any] = None,
        creationflags: int = 0,
        restore_signals: bool = True,
        start_new_session: bool = False,
        pass_fds: Sequence[int] = (),
        timeout: Optional[float] = None,
    ) -> int:
        
        if shell and isinstance(args, str) and env is None:
            sb = _create_sandbox_from_config(cwd=str(cwd) if cwd else None)
            result = sb.run(args, check=True, timeout=timeout)
            return result.returncode

        return original_check_call(
            args,
            bufsize=bufsize,
            executable=executable,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            preexec_fn=preexec_fn,
            close_fds=close_fds,
            shell=shell,
            cwd=cwd,
            env=env,
            universal_newlines=universal_newlines,
            startupinfo=startupinfo,
            creationflags=creationflags,
            restore_signals=restore_signals,
            start_new_session=start_new_session,
            pass_fds=pass_fds,
            timeout=timeout,
        )

    return sandboxed_check_call


def _create_sandboxed_check_output():
    """Create a sandboxed version of subprocess.check_output."""
    original_check_output = _originals["check_output"]

    def sandboxed_check_output(
        args: Union[str, Sequence[str]],
        *,
        bufsize: int = -1,
        executable: Optional[str] = None,
        stdin: Optional[Union[int, IO]] = None,
        stderr: Optional[Union[int, IO]] = None,
        preexec_fn: Optional[Any] = None,
        close_fds: bool = True,
        shell: bool = False,
        cwd: Optional[str] = None,
        env: Optional[Mapping[str, str]] = None,
        universal_newlines: Optional[bool] = None,
        startupinfo: Optional[Any] = None,
        creationflags: int = 0,
        restore_signals: bool = True,
        start_new_session: bool = False,
        pass_fds: Sequence[int] = (),
        timeout: Optional[float] = None,
        text: bool = False,
        encoding: Optional[str] = None,
        errors: Optional[str] = None,
    ) -> Union[str, bytes]:
        
        if shell and isinstance(args, str) and env is None:
            sb = _create_sandbox_from_config(cwd=str(cwd) if cwd else None)
            result = sb.run(
                args,
                capture_output=True,
                check=True,
                timeout=timeout,
                text=text or (encoding is not None) or (universal_newlines is True),
            )
            return result.stdout

        return original_check_output(
            args,
            bufsize=bufsize,
            executable=executable,
            stdin=stdin,
            stderr=stderr,
            preexec_fn=preexec_fn,
            close_fds=close_fds,
            shell=shell,
            cwd=cwd,
            env=env,
            universal_newlines=universal_newlines,
            startupinfo=startupinfo,
            creationflags=creationflags,
            restore_signals=restore_signals,
            start_new_session=start_new_session,
            pass_fds=pass_fds,
            timeout=timeout,
            text=text,
            encoding=encoding,
            errors=errors,
        )

    return sandboxed_check_output


def _create_sandboxed_getoutput():
    """Create a sandboxed version of subprocess.getoutput."""

    def sandboxed_getoutput(cmd: str) -> str:
        sb = _create_sandbox_from_config()
        try:
            result = sb.run(cmd, capture_output=True, check=False, text=True)
            return result.stdout + result.stderr
        except SandboxError:
            return ""

    return sandboxed_getoutput


def _create_sandboxed_getstatusoutput():
    """Create a sandboxed version of subprocess.getstatusoutput."""

    def sandboxed_getstatusoutput(cmd: str) -> Tuple[int, str]:
        sb = _create_sandbox_from_config()
        try:
            result = sb.run(cmd, capture_output=True, check=False, text=True)
            return result.returncode, result.stdout + result.stderr
        except SandboxError as e:
            return 1, str(e)

    return sandboxed_getstatusoutput


# =============================================================================
# PATCH / UNPATCH
# =============================================================================

def patch_subprocess(
    *,
    zypi_url: str = "http://localhost:4000",
    image: str = "ubuntu:24.04",
    rw: Optional[List[str]] = None,
    network: bool = False,
    share_home: bool = True,
    env_passthrough: Optional[List[str]] = None,
    allow_secrets: Optional[List[str]] = None,
) -> None:
    """Monkey-patch subprocess to use Zypi containers."""
    global _patched, _patch_config, _originals
    
    if _patched:
        return
    
    _originals = {
        "run": subprocess.run,
        "call": subprocess.call,
        "check_call": subprocess.check_call,
        "check_output": subprocess.check_output,
        "Popen": subprocess.Popen,
        "getoutput": subprocess.getoutput,
        "getstatusoutput": subprocess.getstatusoutput,
    }
    
    final_env_passthrough = list(env_passthrough or DEFAULT_ENV_PASSTHROUGH)
    for var in ESSENTIAL_ENV_VARS:
        if var not in final_env_passthrough:
            final_env_passthrough.append(var)
    
    _patch_config = {
        "zypi_url": zypi_url,
        "image": image,
        "network": network,
        "env_passthrough": final_env_passthrough,
    }
    
    subprocess.run = _create_sandboxed_run()
    subprocess.call = _create_sandboxed_call()
    subprocess.check_call = _create_sandboxed_check_call()
    subprocess.check_output = _create_sandboxed_check_output()
    subprocess.Popen = SandboxedPopen
    subprocess.getoutput = _create_sandboxed_getoutput()
    subprocess.getstatusoutput = _create_sandboxed_getstatusoutput()
    
    _patched = True


def unpatch_subprocess() -> None:
    """Remove the subprocess monkey-patch."""
    global _patched, _originals
    
    if not _patched:
        return

    subprocess.run = _originals["run"]
    subprocess.call = _originals["call"]
    subprocess.check_call = _originals["check_call"]
    subprocess.check_output = _originals["check_output"]
    subprocess.Popen = _originals["Popen"]
    subprocess.getoutput = _originals["getoutput"]
    subprocess.getstatusoutput = _originals["getstatusoutput"]

    _patched = False
    _originals = {}
