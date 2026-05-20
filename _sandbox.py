"""
bubbleproc - Sandboxed subprocess execution via Zypi Firecracker VMs

Provides subprocess patching to run shell commands in isolated VMs.
"""

from __future__ import annotations

import subprocess
import shlex
import os
import sys
import io
from dataclasses import dataclass, field
from typing import Any, Optional, List, Dict, Union, Sequence, Mapping, IO, Tuple

try:
    from zypi_client import ZypiClient
except ImportError:
    ZypiClient = None

__all__ = [
    "Sandbox",
    "SandboxError",
    "run",
    "check_output",
    "patch_subprocess",
    "unpatch_subprocess",
    "create_aider_sandbox",
    "is_patched",
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
    """
    Sandbox that executes commands in Zypi Firecracker VMs.
    """
    # Zypi connection settings
    zypi_url: str = "http://localhost:4000"
    image: str = "ubuntu:24.04"
    
    # Environment configuration
    env: Dict[str, str] = field(default_factory=dict)
    env_passthrough: List[str] = field(default_factory=list)
    cwd: Optional[str] = None
    timeout: Optional[float] = None
    
    # File injection
    files: Dict[str, str] = field(default_factory=dict)
    
    # Legacy fields (kept for API compatibility, some mapped to Zypi)
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
                "zypi_client module not found. Ensure zypi_client.py is available."
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
        command: str,
        *,
        capture_output: bool = False,
        text: bool = True,
        check: bool = False,
        timeout: Optional[float] = None,
        input: Optional[Union[str, bytes]] = None,
        **kwargs: Any,
    ) -> subprocess.CompletedProcess:
        """Run a shell command in the sandbox."""
        
        # Build environment from passthrough + explicit env
        exec_env = {}
        for var in self.env_passthrough:
            if var in os.environ:
                exec_env[var] = os.environ[var]
        exec_env.update(self.env)
        
        cmd = ["/bin/sh", "-c", command]
        
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
        
        # Format output based on text flag
        if text:
            stdout_result = stdout if capture_output else ""
            stderr_result = stderr if capture_output else ""
        else:
            stdout_result = stdout.encode("utf-8") if capture_output else b""
            stderr_result = stderr.encode("utf-8") if capture_output else b""
        
        result = subprocess.CompletedProcess(
            args=command,
            returncode=exit_code,
            stdout=stdout_result,
            stderr=stderr_result,
        )
        
        if check and exit_code != 0:
            raise subprocess.CalledProcessError(
                exit_code, command, output=result.stdout, stderr=result.stderr
            )
        
        return result
    
    def check_output(
        self,
        command: str,
        *,
        text: bool = True,
        **kwargs: Any,
    ) -> Union[str, bytes]:
        """Run command and return its output. Raises on non-zero exit."""
        result = self.run(command, capture_output=True, text=text, check=True, **kwargs)
        return result.stdout


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def _args_to_shell_command(args: Union[str, Sequence[str]]) -> str:
    """Convert args to a shell command string."""
    if isinstance(args, str):
        return args
    return shlex.join(args)


def _should_sandbox(args, shell: bool, env: Optional[Mapping] = None) -> bool:
    """Determine if a subprocess call should be sandboxed."""
    if env and env.get("BUBBLEPROC_DISABLE"):
        return False
    return shell


# =============================================================================
# CONVENIENCE FUNCTIONS
# =============================================================================

def run(
    command: str,
    *,
    ro: Optional[List[str]] = None,
    rw: Optional[List[str]] = None,
    network: bool = False,
    share_home: bool = False,
    env: Optional[Dict[str, str]] = None,
    env_passthrough: Optional[List[str]] = None,
    capture_output: bool = False,
    text: bool = True,
    check: bool = False,
    cwd: Optional[str] = None,
    timeout: Optional[float] = None,
    zypi_url: str = "http://localhost:4000",
    image: str = "ubuntu:24.04",
    **kwargs: Any,
) -> subprocess.CompletedProcess:
    """Run a command in a sandbox."""
    sb = Sandbox(
        zypi_url=zypi_url,
        image=image,
        ro=ro or [],
        rw=rw or [],
        network=network,
        share_home=share_home,
        env=env or {},
        env_passthrough=env_passthrough or [],
        cwd=cwd,
        timeout=timeout,
    )
    return sb.run(
        command,
        capture_output=capture_output,
        text=text,
        check=check,
        **kwargs,
    )


def check_output(
    command: str,
    *,
    ro: Optional[List[str]] = None,
    rw: Optional[List[str]] = None,
    network: bool = False,
    text: bool = True,
    cwd: Optional[str] = None,
    zypi_url: str = "http://localhost:4000",
    image: str = "ubuntu:24.04",
    **kwargs: Any,
) -> Union[str, bytes]:
    """Run a sandboxed command and return its output."""
    sb = Sandbox(
        zypi_url=zypi_url,
        image=image,
        ro=ro or [],
        rw=rw or [],
        network=network,
        cwd=cwd,
    )
    return sb.check_output(command, text=text, **kwargs)


# =============================================================================
# SUBPROCESS PATCHING STATE
# =============================================================================

_originals: Dict[str, Any] = {}
_patched = False
_patch_config: Dict[str, Any] = {}


def _create_sandbox_from_config(cwd: Optional[str] = None) -> Sandbox:
    """Create a Sandbox instance using the current patch configuration."""
    env_passthrough = list(_patch_config.get("env_passthrough", DEFAULT_ENV_PASSTHROUGH))
    
    for var in ESSENTIAL_ENV_VARS:
        if var not in env_passthrough:
            env_passthrough.append(var)
    
    return Sandbox(
        zypi_url=_patch_config.get("zypi_url", "http://localhost:4000"),
        image=_patch_config.get("image", "ubuntu:24.04"),
        rw=_patch_config.get("rw", []),
        network=_patch_config.get("network", False),
        share_home=_patch_config.get("share_home", True),
        env_passthrough=env_passthrough,
        allow_secrets=_patch_config.get("allow_secrets", []),
        cwd=cwd,
    )


# =============================================================================
# SANDBOXED POPEN
# =============================================================================

class SandboxedPopen:
    """
    A Popen-like wrapper that runs commands in a Zypi sandbox.
    """
    
    def __init__(
        self,
        args,
        bufsize=-1,
        executable=None,
        stdin=None,
        stdout=None,
        stderr=None,
        preexec_fn=None,
        close_fds=True,
        shell=False,
        cwd=None,
        env=None,
        universal_newlines=None,
        startupinfo=None,
        creationflags=0,
        restore_signals=True,
        start_new_session=False,
        pass_fds=(),
        *,
        group=None,
        extra_groups=None,
        user=None,
        umask=-1,
        encoding=None,
        errors=None,
        text=None,
        pipesize=-1,
        process_group=None,
    ):
        self._sandbox_mode = _should_sandbox(args, shell, env)
        self._completed = False
        self._returncode = None
        self._stdout_data = None
        self._stderr_data = None
        self._text_mode = text or universal_newlines or encoding or errors
        self._real_popen = None
        
        if self._sandbox_mode:
            command = _args_to_shell_command(args)
            sb = _create_sandbox_from_config(cwd=cwd)
            
            try:
                result = sb.run(command, capture_output=True, text=bool(self._text_mode))
                self._returncode = result.returncode
                self._stdout_data = result.stdout
                self._stderr_data = result.stderr
            except SandboxError as e:
                self._returncode = 1
                self._stderr_data = str(e) if self._text_mode else str(e).encode("utf-8")
                self._stdout_data = "" if self._text_mode else b""
            
            self._completed = True
            self.stdin = None
            self.stdout = self._make_pipe(self._stdout_data, stdout)
            self.stderr = self._make_pipe(self._stderr_data, stderr)
            self.pid = -1
            self.args = args
        else:
            OriginalPopen = _originals.get("Popen", subprocess.Popen)
            
            popen_kwargs = dict(
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
                encoding=encoding,
                errors=errors,
                text=text,
            )
            
            if sys.version_info >= (3, 9):
                popen_kwargs["group"] = group
                popen_kwargs["extra_groups"] = extra_groups
                popen_kwargs["user"] = user
                popen_kwargs["umask"] = umask
            
            if sys.version_info >= (3, 10):
                popen_kwargs["pipesize"] = pipesize
            
            if sys.version_info >= (3, 11):
                popen_kwargs["process_group"] = process_group
            
            self._real_popen = OriginalPopen(args, **popen_kwargs)
            self.stdin = self._real_popen.stdin
            self.stdout = self._real_popen.stdout
            self.stderr = self._real_popen.stderr
            self.pid = self._real_popen.pid
            self.args = self._real_popen.args
    
    def _make_pipe(self, data, pipe_request) -> Optional[IO]:
        """Create a file-like object if pipe was requested."""
        if pipe_request == subprocess.PIPE:
            if self._text_mode:
                return io.StringIO(data or "")
            else:
                return io.BytesIO(data or b"")
        return None
    
    @property
    def returncode(self) -> Optional[int]:
        if self._sandbox_mode:
            return self._returncode
        return self._real_popen.returncode
    
    def poll(self) -> Optional[int]:
        if self._sandbox_mode:
            return self._returncode
        return self._real_popen.poll()
    
    def wait(self, timeout=None) -> int:
        if self._sandbox_mode:
            return self._returncode
        return self._real_popen.wait(timeout=timeout)
    
    def communicate(self, input=None, timeout=None) -> Tuple[Any, Any]:
        if self._sandbox_mode:
            return (self._stdout_data, self._stderr_data)
        return self._real_popen.communicate(input=input, timeout=timeout)
    
    def send_signal(self, sig):
        if not self._sandbox_mode:
            self._real_popen.send_signal(sig)
    
    def terminate(self):
        if not self._sandbox_mode:
            self._real_popen.terminate()
    
    def kill(self):
        if not self._sandbox_mode:
            self._real_popen.kill()
    
    def __enter__(self):
        if self._sandbox_mode:
            return self
        return self._real_popen.__enter__()
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._sandbox_mode:
            if self.stdout:
                self.stdout.close()
            if self.stderr:
                self.stderr.close()
            return False
        return self._real_popen.__exit__(exc_type, exc_val, exc_tb)


# =============================================================================
# SANDBOXED SUBPROCESS FUNCTIONS
# =============================================================================

def _create_sandboxed_run():
    """Create a sandboxed version of subprocess.run."""
    original_run = _originals["run"]
    
    def sandboxed_run(
        args,
        bufsize=-1,
        executable=None,
        stdin=None,
        stdout=None,
        stderr=None,
        preexec_fn=None,
        close_fds=True,
        shell=False,
        cwd=None,
        env=None,
        universal_newlines=None,
        startupinfo=None,
        creationflags=0,
        restore_signals=True,
        start_new_session=False,
        pass_fds=(),
        *,
        capture_output=False,
        timeout=None,
        check=False,
        encoding=None,
        errors=None,
        text=None,
        input=None,
        **kwargs,
    ):
        use_text = text or universal_newlines or encoding or errors
        
        if _should_sandbox(args, shell, env):
            command = _args_to_shell_command(args)
            sb = _create_sandbox_from_config(cwd=cwd)
            return sb.run(
                command,
                capture_output=capture_output,
                text=bool(use_text),
                check=check,
                timeout=timeout,
                input=input,
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
            encoding=encoding,
            errors=errors,
            text=text,
            input=input,
            **kwargs,
        )
    
    return sandboxed_run


def _create_sandboxed_call():
    """Create a sandboxed version of subprocess.call."""
    original_call = _originals["call"]
    
    def sandboxed_call(args, *, timeout=None, **kwargs):
        shell = kwargs.get("shell", False)
        env = kwargs.get("env")
        
        if _should_sandbox(args, shell, env):
            command = _args_to_shell_command(args)
            cwd = kwargs.pop("cwd", None)
            sb = _create_sandbox_from_config(cwd=cwd)
            result = sb.run(command, capture_output=False, timeout=timeout)
            return result.returncode
        
        return original_call(args, timeout=timeout, **kwargs)
    
    return sandboxed_call


def _create_sandboxed_check_call():
    """Create a sandboxed version of subprocess.check_call."""
    original_check_call = _originals["check_call"]
    
    def sandboxed_check_call(args, *, timeout=None, **kwargs):
        shell = kwargs.get("shell", False)
        env = kwargs.get("env")
        
        if _should_sandbox(args, shell, env):
            command = _args_to_shell_command(args)
            cwd = kwargs.pop("cwd", None)
            sb = _create_sandbox_from_config(cwd=cwd)
            result = sb.run(command, capture_output=False, check=True, timeout=timeout)
            return result.returncode
        
        return original_check_call(args, timeout=timeout, **kwargs)
    
    return sandboxed_check_call


def _create_sandboxed_check_output():
    """Create a sandboxed version of subprocess.check_output."""
    original_check_output = _originals["check_output"]
    
    def sandboxed_check_output(args, *, timeout=None, **kwargs):
        shell = kwargs.get("shell", False)
        env = kwargs.get("env")
        
        if _should_sandbox(args, shell, env):
            command = _args_to_shell_command(args)
            cwd = kwargs.pop("cwd", None)
            text = kwargs.pop("text", kwargs.pop("universal_newlines", None))
            encoding = kwargs.pop("encoding", None)
            errors = kwargs.pop("errors", None)
            use_text = text or encoding or errors
            
            sb = _create_sandbox_from_config(cwd=cwd)
            result = sb.run(
                command,
                capture_output=True,
                check=True,
                text=bool(use_text),
                timeout=timeout,
            )
            return result.stdout
        
        return original_check_output(args, timeout=timeout, **kwargs)
    
    return sandboxed_check_output


def _create_sandboxed_getstatusoutput():
    """Create a sandboxed version of subprocess.getstatusoutput."""
    
    def sandboxed_getstatusoutput(cmd: str) -> Tuple[int, str]:
        sb = _create_sandbox_from_config()
        try:
            result = sb.run(cmd, capture_output=True, text=True)
            output = (result.stdout or "") + (result.stderr or "")
            if output.endswith("\n"):
                output = output[:-1]
            return result.returncode, output
        except SandboxError as e:
            return 1, str(e)
    
    return sandboxed_getstatusoutput


def _create_sandboxed_getoutput():
    """Create a sandboxed version of subprocess.getoutput."""
    
    def sandboxed_getoutput(cmd: str) -> str:
        sb = _create_sandbox_from_config()
        try:
            result = sb.run(cmd, capture_output=True, text=True)
            output = (result.stdout or "") + (result.stderr or "")
            if output.endswith("\n"):
                output = output[:-1]
            return output
        except SandboxError:
            return ""
    
    return sandboxed_getoutput


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
    """
    Monkey-patch subprocess module to use Zypi sandboxing for shell commands.
    
    Only shell commands (shell=True with string args) are sandboxed.
    Direct executable calls (shell=False or list args) pass through unchanged.
    """
    global _patched, _patch_config, _originals
    
    if _patched:
        return
    
    _originals = {
        "run": subprocess.run,
        "call": subprocess.call,
        "check_call": subprocess.check_call,
        "check_output": subprocess.check_output,
        "Popen": subprocess.Popen,
        "getstatusoutput": subprocess.getstatusoutput,
        "getoutput": subprocess.getoutput,
    }
    
    final_env_passthrough = list(env_passthrough or DEFAULT_ENV_PASSTHROUGH)
    for var in ESSENTIAL_ENV_VARS:
        if var not in final_env_passthrough:
            final_env_passthrough.append(var)
    
    _patch_config = {
        "zypi_url": zypi_url,
        "image": image,
        "rw": rw or [],
        "network": network,
        "share_home": share_home,
        "env_passthrough": final_env_passthrough,
        "allow_secrets": allow_secrets or [],
    }
    
    subprocess.run = _create_sandboxed_run()
    subprocess.call = _create_sandboxed_call()
    subprocess.check_call = _create_sandboxed_check_call()
    subprocess.check_output = _create_sandboxed_check_output()
    subprocess.Popen = SandboxedPopen
    subprocess.getstatusoutput = _create_sandboxed_getstatusoutput()
    subprocess.getoutput = _create_sandboxed_getoutput()
    
    _patched = True


def unpatch_subprocess() -> None:
    """Remove all subprocess monkey-patches and restore originals."""
    global _patched, _originals
    
    if not _patched or not _originals:
        return
    
    subprocess.run = _originals["run"]
    subprocess.call = _originals["call"]
    subprocess.check_call = _originals["check_call"]
    subprocess.check_output = _originals["check_output"]
    subprocess.Popen = _originals["Popen"]
    subprocess.getstatusoutput = _originals["getstatusoutput"]
    subprocess.getoutput = _originals["getoutput"]
    
    _originals = {}
    _patched = False


def is_patched() -> bool:
    """Check if subprocess is currently patched."""
    return _patched


# =============================================================================
# CONVENIENCE SANDBOX CREATORS
# =============================================================================

def create_aider_sandbox(
    project_dir: str,
    *,
    network: bool = True,
    allow_gpg: bool = False,
    allow_ssh: bool = False,
    zypi_url: str = "http://localhost:4000",
    image: str = "ubuntu:24.04",
) -> Sandbox:
    """Create a sandbox configured for Aider CLI usage."""
    allow_secrets = []
    if allow_gpg:
        allow_secrets.append(".gnupg")
    if allow_ssh:
        allow_secrets.append(".ssh")
    
    return Sandbox(
        zypi_url=zypi_url,
        image=image,
        rw=[project_dir, "/tmp"],
        network=network,
        share_home=True,
        env_passthrough=ESSENTIAL_ENV_VARS + [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY",
            "GOOGLE_API_KEY",
            "AZURE_OPENAI_API_KEY",
            "GEMINI_API_KEY",
            "AZURE_API_KEY",
            "AZURE_API_BASE",
            "AZURE_API_VERSION",
            "DEEPSEEK_API_KEY",
            "GROQ_API_KEY",
            "COHERE_API_KEY",
            "MISTRAL_API_KEY",
            "OLLAMA_API_BASE",
            "OPENAI_API_BASE",
            "OPENAI_API_TYPE",
            "OPENAI_API_VERSION",
            "GIT_AUTHOR_NAME",
            "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME",
            "GIT_COMMITTER_EMAIL",
            "GIT_SSH_COMMAND",
            "GIT_ASKPASS",
            "COLORTERM",
            "CLICOLOR",
            "FORCE_COLOR",
            "NO_COLOR",
            "PYTHONPATH",
            "VIRTUAL_ENV",
            "EDITOR",
            "VISUAL",
        ],
        allow_secrets=allow_secrets,
    )
