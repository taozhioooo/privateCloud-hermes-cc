"""Render compose fragments from the user registry."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader, StrictUndefined

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from lib import registry as reg
else:
    from . import registry as reg


PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
TEMPLATE_DIR = PROJECT_ROOT / "compose" / "templates"
RENDERED_DIR = PROJECT_ROOT / "compose" / "rendered"
BASE_YML = PROJECT_ROOT / "compose" / "base.yml"
USER_TEMPLATE = "user.yml.j2"


def _env() -> Environment:
    return Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )


def render_user(
    user: dict[str, Any],
    defaults: dict[str, Any],
    ports_config: dict[str, Any],
    output_dir: Path | str = RENDERED_DIR,
) -> Path:
    ports = reg.get_ports(user["seq"], ports_config)
    resources = reg.get_effective_resources(user, defaults)
    ctx = {
        "name": user["name"],
        "employee_id": user.get("employee_id") or user["name"],
        "user_data_dir": f"{user['name']}-{user.get('employee_id') or user['name']}",
        "seq": user["seq"],
        "domain": user.get("domain", "engineering"),
        "role": user.get("role", "engineer"),
        "ssh_public_keys": reg.normalize_ssh_public_keys(user.get("ssh_public_keys")),
        "image_hermes": defaults["image_hermes"],
        "image_claude": defaults["image_claude"],
        "hermes_mode": defaults.get("hermes_mode", "gateway"),
        "resources": resources,
        "h_ssh_port": ports["h_ssh"],
        "h_web_start": ports["h_web_start"],
        "h_web_end": ports["h_web_end"],
        "c_ssh_port": ports["c_ssh"],
        "c_web_start": ports["c_web_start"],
        "c_web_end": ports["c_web_end"],
    }
    env = _env()
    tmpl = env.get_template(USER_TEMPLATE)
    content = tmpl.render(**ctx)
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"user.{user['name']}.yml"
    out_path.write_text(content, encoding="utf-8")
    return out_path


def render_all(
    registry_path: Path | str | None = None,
    output_dir: Path | str = RENDERED_DIR,
    include_disabled: bool = False,
) -> list[Path]:
    registry_path = Path(registry_path) if registry_path else reg.default_registry_path()
    registry = reg.load_registry(registry_path)
    conflicts = reg.find_port_conflicts(registry)
    if conflicts:
        raise reg.RegistryError("registry has conflicts:\n  - " + "\n  - ".join(conflicts))
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    target_names: set[str] = set()
    results: list[Path] = []
    for user in registry.get("users", []):
        if not include_disabled and not user.get("enabled", True):
            continue
        path = render_user(user, registry["defaults"], registry["ports"], out_dir)
        target_names.add(user["name"])
        results.append(path)

    for existing in out_dir.glob("user.*.yml"):
        name = existing.stem.removeprefix("user.")
        if name not in target_names:
            existing.unlink()

    return results


def get_compose_files(
    registry_path: Path | str | None = None,
    compose_dir: Path | str | None = None,
    users: list[str] | None = None,
) -> list[Path]:
    registry_path = Path(registry_path) if registry_path else reg.default_registry_path()
    compose_dir = Path(compose_dir) if compose_dir else PROJECT_ROOT / "compose"
    rendered_dir = compose_dir / "rendered"
    base = compose_dir / "base.yml"
    files = [base]
    registry = reg.load_registry(registry_path)
    for u in reg.list_users(registry):
        if not u.get("enabled", True):
            continue
        if users and u["name"] not in users:
            continue
        p = rendered_dir / f"user.{u['name']}.yml"
        if p.exists():
            files.append(p)
    return files


def main() -> int:
    try:
        files = render_all()
    except reg.RegistryError as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        return 1
    print(f"rendered {len(files)} user compose file(s):")
    for f in files:
        print(f"  - {f.relative_to(PROJECT_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
