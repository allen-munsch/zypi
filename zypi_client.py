"""
HTTP client for Zypi container runtime.
"""
import requests
from typing import Optional, Dict, List, Tuple
from dataclasses import dataclass

@dataclass
class ZypiClient:
    base_url: str = "http://localhost:4000"
    default_image: str = "ubuntu:24.04"  # Must be pre-imported into Zypi
    timeout: int = 300
    
    def exec(
        self,
        cmd: List[str],
        image: Optional[str] = None,
        env: Optional[Dict[str, str]] = None,
        workdir: Optional[str] = None,
        files: Optional[Dict[str, str]] = None,
        timeout: Optional[int] = None,
    ) -> Tuple[int, str, str]:
        """
        Execute command in Zypi container.
        Returns (exit_code, stdout, stderr).
        """
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
        if timeout:
            payload["timeout"] = timeout
            
        response = requests.post(
            f"{self.base_url}/exec",
            json=payload,
            timeout=timeout or self.timeout,
        )
        response.raise_for_status()
        data = response.json()
        return data["exit_code"], data["stdout"], data["stderr"]
    
    def health_check(self) -> bool:
        """Check if Zypi is running."""
        try:
            r = requests.get(f"{self.base_url}/health", timeout=5)
            return r.status_code == 200
        except:
            return False
