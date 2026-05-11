"""User registry operations (Single Source of Truth)."""
from __future__ import annotations

import copy
import re
from pathlib import Path
from typing import Any

import yaml


REGISTRY_VERSION = 1
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}[a-z0-9]$")
SSH_KEY_RE = re.compile(
    r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) "
)


class RegistryError(Exception):
    pass


def _default_registry() -> dict[str, Any]:
    return {
        "version": REGISTRY_VERSION,
        "defaults": {
            "image_hermes": "registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:latest",
            "image_claude": "registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:latest",
            "resources": {
                "hermes": {"cpus": "2.0", "memory": "2G"},
                "claude": {"cpus": "4.0", "memory": "4G"},
            },
            "hermes_mode": "gateway",
        },
        "ports": {
            "hermes_base": 10001,
            "claude_base": 11001,
            "step": 100,
            "range_size": 100,
        },
        "users": [],
    }


def load_registry(path: str | Path) -> dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise RegistryError(f"registry file not found: {p}")
    with p.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        raise RegistryError(f"invalid registry format: {p}")
    base = _default_registry()
    base["version"] = data.get("version", REGISTRY_VERSION)
    if "defaults" in data and isinstance(data["defaults"], dict):
        _deep_merge(base["defaults"], data["defaults"])
    if "ports" in data and isinstance(data["ports"], dict):
        base["ports"].update(data["ports"])
    base["users"] = data.get("users") or []
    for u in base["users"]:
        u.setdefault("enabled", True)
        u.setdefault("ssh_public_keys", [])
        u.setdefault("domain", "engineering")
        u.setdefault("role", "engineer")
    return base


def save_registry(registry: dict[str, Any], path: str | Path) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    ordered = {
        "version": registry.get("version", REGISTRY_VERSION),
        "defaults": registry.get("defaults", {}),
        "ports": registry.get("ports", {}),
        "users": registry.get("users", []),
    }
    with p.open("w", encoding="utf-8") as f:
        yaml.safe_dump(
            ordered,
            f,
            sort_keys=False,
            allow_unicode=True,
            default_flow_style=False,
            width=1000,
        )


def _deep_merge(base: dict, override: dict) -> dict:
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def get_user(registry: dict[str, Any], name: str) -> dict[str, Any] | None:
    for u in registry.get("users", []):
        if u["name"] == name:
            return u
    return None


def list_users(registry: dict[str, Any]) -> list[dict[str, Any]]:
    return sorted(registry.get("users", []), key=lambda u: u.get("seq", 0))


def validate_name(name: str) -> None:
    if not NAME_RE.match(name):
        raise RegistryError(
            f"invalid name '{name}': must be lowercase alphanumeric with hyphens, "
            f"start with a letter, 2-32 chars"
        )


def validate_ssh_key(key: str) -> None:
    if not SSH_KEY_RE.match(key):
        raise RegistryError(
            f"invalid SSH public key format: {key[:40]}... (must start with ssh-ed25519/ssh-rsa/...)"
        )


def allocate_seq(registry: dict[str, Any], preferred: int | None = None) -> int:
    used = {u["seq"] for u in registry.get("users", []) if "seq" in u}
    if preferred is not None:
        if preferred < 1 or preferred > 70:
            raise RegistryError(f"seq {preferred} out of range [1, 70]")
        if preferred in used:
            raise RegistryError(f"seq {preferred} already taken")
        return preferred
    for i in range(1, 71):
        if i not in used:
            return i
    raise RegistryError("no free seq available (max 70 users)")


def release_seq(registry: dict[str, Any], name: str) -> int | None:
    user = get_user(registry, name)
    return user["seq"] if user else None


def add_user(
    registry: dict[str, Any],
    name: str,
    seq: int | None = None,
    domain: str = "engineering",
    role: str = "engineer",
    ssh_public_keys: list[str] | None = None,
    resources_override: dict | None = None,
    enabled: bool = True,
) -> dict[str, Any]:
    validate_name(name)
    if get_user(registry, name) is not None:
        raise RegistryError(f"user '{name}' already exists")
    keys = ssh_public_keys or []
    for k in keys:
        validate_ssh_key(k)
    seq_num = allocate_seq(registry, preferred=seq)
    user = {
        "name": name,
        "seq": seq_num,
        "domain": domain,
        "role": role,
        "ssh_public_keys": keys,
        "enabled": enabled,
    }
    if resources_override:
        user["resources"] = resources_override
    registry.setdefault("users", []).append(user)
    return user


def remove_user(registry: dict[str, Any], name: str) -> dict[str, Any]:
    users = registry.get("users", [])
    for i, u in enumerate(users):
        if u["name"] == name:
            return users.pop(i)
    raise RegistryError(f"user '{name}' not found")


def update_user(
    registry: dict[str, Any],
    name: str,
    *,
    domain: str | None = None,
    role: str | None = None,
    add_pubkey: str | None = None,
    enabled: bool | None = None,
    resources_override: dict | None = None,
) -> dict[str, Any]:
    user = get_user(registry, name)
    if user is None:
        raise RegistryError(f"user '{name}' not found")
    if domain is not None:
        user["domain"] = domain
    if role is not None:
        user["role"] = role
    if add_pubkey is not None:
        validate_ssh_key(add_pubkey)
        keys = user.setdefault("ssh_public_keys", [])
        if add_pubkey not in keys:
            keys.append(add_pubkey)
    if enabled is not None:
        user["enabled"] = enabled
    if resources_override is not None:
        user["resources"] = resources_override
    return user


def get_ports(seq: int, ports_config: dict[str, Any]) -> dict[str, int]:
    h_base = ports_config["hermes_base"]
    c_base = ports_config["claude_base"]
    step = ports_config.get("step", 100)
    range_size = ports_config.get("range_size", 100)
    h_ssh = h_base + (seq - 1) * step
    c_ssh = c_base + (seq - 1) * step
    return {
        "h_ssh": h_ssh,
        "h_web_start": h_ssh + 1,
        "h_web_end": h_ssh + range_size - 2,
        "c_ssh": c_ssh,
        "c_web_start": c_ssh + 1,
        "c_web_end": c_ssh + range_size - 2,
    }


def get_effective_resources(user: dict, defaults: dict) -> dict:
    base = copy.deepcopy(defaults.get("resources", {}))
    override = user.get("resources") or {}
    _deep_merge(base, override)
    return base


def find_port_conflicts(registry: dict[str, Any]) -> list[str]:
    conflicts: list[str] = []
    seen_seq: dict[int, str] = {}
    seen_name: set[str] = set()
    ports_cfg = registry.get("ports", {})
    used_ranges: list[tuple[int, int, str, str]] = []
    for u in registry.get("users", []):
        name = u.get("name", "")
        if name in seen_name:
            conflicts.append(f"duplicate name: {name}")
        seen_name.add(name)
        seq = u.get("seq")
        if seq is None:
            conflicts.append(f"user {name}: missing seq")
            continue
        if seq in seen_seq:
            conflicts.append(f"duplicate seq {seq}: {seen_seq[seq]} and {name}")
        seen_seq[seq] = name
        p = get_ports(seq, ports_cfg)
        used_ranges.append((p["h_ssh"], p["h_web_end"], name, "hermes"))
        used_ranges.append((p["c_ssh"], p["c_web_end"], name, "claude"))
    used_ranges.sort()
    for i in range(len(used_ranges) - 1):
        a_start, a_end, a_name, a_kind = used_ranges[i]
        b_start, b_end, b_name, b_kind = used_ranges[i + 1]
        if b_start <= a_end:
            conflicts.append(
                f"port overlap: {a_name}/{a_kind} [{a_start}-{a_end}] "
                f"vs {b_name}/{b_kind} [{b_start}-{b_end}]"
            )
    return conflicts


def default_registry_path() -> Path:
    here = Path(__file__).resolve().parent.parent.parent
    return here / "users" / "users.yaml"
