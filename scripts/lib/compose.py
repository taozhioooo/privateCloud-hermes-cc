"""Docker compose command wrapper."""
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Iterable

from . import render


def build_compose_cmd(
    base_yml: Path | str,
    rendered_dir: Path | str,
    users: list[str] | None = None,
) -> list[str]:
    base_yml = Path(base_yml)
    # project root = parent of compose/base.yml  (i.e. the repo root)
    project_dir = base_yml.parent.parent
    env_file = project_dir / ".env"
    cmd = ["docker", "compose",
           "--project-name", "hermes",
           "--project-directory", str(project_dir)]
    if env_file.exists():
        cmd.extend(["--env-file", str(env_file)])
    cmd.extend(["-f", str(base_yml)])
    rendered = Path(rendered_dir)
    if users:
        for name in users:
            p = rendered / f"user.{name}.yml"
            if p.exists():
                cmd.extend(["-f", str(p)])
    else:
        for p in sorted(rendered.glob("user.*.yml")):
            cmd.extend(["-f", str(p)])
    return cmd


def run_compose(cmd: list[str], *, capture: bool = False) -> tuple[int, str, str]:
    if capture:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc.returncode, proc.stdout, proc.stderr
    proc = subprocess.run(cmd)
    return proc.returncode, "", ""


def _services_for(name: str) -> list[str]:
    return [f"hermes-{name}", f"claude-{name}"]


def up_user(
    name: str,
    base_yml: Path | str,
    rendered_dir: Path | str,
    detach: bool = True,
) -> int:
    cmd = build_compose_cmd(base_yml, rendered_dir, users=[name])
    cmd.append("up")
    if detach:
        cmd.append("-d")
    cmd.extend(_services_for(name))
    rc, _, _ = run_compose(cmd)
    return rc


def down_user(
    name: str,
    base_yml: Path | str,
    rendered_dir: Path | str,
    volumes: bool = False,
) -> int:
    cmd = build_compose_cmd(base_yml, rendered_dir, users=[name])
    cmd.append("rm")
    cmd.extend(["-fs"])
    if volumes:
        cmd.append("-v")
    cmd.extend(_services_for(name))
    rc, _, _ = run_compose(cmd)
    return rc


def restart_user(
    name: str,
    base_yml: Path | str,
    rendered_dir: Path | str,
) -> int:
    cmd = build_compose_cmd(base_yml, rendered_dir, users=[name])
    cmd.append("restart")
    cmd.extend(_services_for(name))
    rc, _, _ = run_compose(cmd)
    return rc


def ps(base_yml: Path | str, rendered_dir: Path | str) -> int:
    cmd = build_compose_cmd(base_yml, rendered_dir)
    cmd.append("ps")
    rc, _, _ = run_compose(cmd)
    return rc


def logs(
    name: str,
    base_yml: Path | str,
    rendered_dir: Path | str,
    follow: bool = False,
    tail: int = 50,
) -> int:
    cmd = build_compose_cmd(base_yml, rendered_dir, users=[name])
    cmd.append("logs")
    cmd.extend(["--tail", str(tail)])
    if follow:
        cmd.append("-f")
    cmd.extend(_services_for(name))
    rc, _, _ = run_compose(cmd)
    return rc


def up_all(
    base_yml: Path | str,
    rendered_dir: Path | str,
    detach: bool = True,
) -> int:
    cmd = build_compose_cmd(base_yml, rendered_dir)
    cmd.append("up")
    if detach:
        cmd.append("-d")
    rc, _, _ = run_compose(cmd)
    return rc


def docker_available() -> bool:
    try:
        proc = subprocess.run(
            ["docker", "version", "--format", "{{.Server.Version}}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return proc.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def docker_compose_available() -> bool:
    try:
        proc = subprocess.run(
            ["docker", "compose", "version"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return proc.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def container_status(name: str) -> str:
    try:
        proc = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Status}}", name],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if proc.returncode != 0:
            return "absent"
        return proc.stdout.strip() or "unknown"
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return "unknown"
