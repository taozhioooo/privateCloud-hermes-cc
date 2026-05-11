"""cluster CLI."""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from lib import compose, registry as reg, render
else:
    from . import compose, registry as reg, render


# --- colors ---
_USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code: str, text: str) -> str:
    if not _USE_COLOR:
        return text
    return f"\033[{code}m{text}\033[0m"


def bold(t: str) -> str: return _c("1", t)
def green(t: str) -> str: return _c("32", t)
def red(t: str) -> str: return _c("31", t)
def yellow(t: str) -> str: return _c("33", t)
def cyan(t: str) -> str: return _c("36", t)
def dim(t: str) -> str: return _c("2", t)


def info(msg: str) -> None:
    print(f"{cyan('[INFO]')} {msg}")


def ok(msg: str) -> None:
    print(f"{green('[OK]')} {msg}")


def warn(msg: str) -> None:
    print(f"{yellow('[WARN]')} {msg}", file=sys.stderr)


def err(msg: str) -> None:
    print(f"{red('[ERROR]')} {msg}", file=sys.stderr)


# --- paths ---
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
REGISTRY_PATH = PROJECT_ROOT / "users" / "users.yaml"
BASE_YML = PROJECT_ROOT / "compose" / "base.yml"
RENDERED_DIR = PROJECT_ROOT / "compose" / "rendered"


def _load_registry() -> dict[str, Any]:
    return reg.load_registry(REGISTRY_PATH)


def _save_registry(registry: dict[str, Any]) -> None:
    reg.save_registry(registry, REGISTRY_PATH)


def _render_and_report() -> None:
    files = render.render_all(REGISTRY_PATH, RENDERED_DIR)
    info(f"rendered {len(files)} compose fragment(s)")


def _read_pubkey(value: str | None) -> str | None:
    if not value:
        return None
    p = Path(value).expanduser()
    if p.is_file():
        return p.read_text(encoding="utf-8").strip()
    return value.strip()


# --- subcommands ---
def cmd_add(args: argparse.Namespace) -> int:
    registry = _load_registry()
    pubkey = _read_pubkey(args.pubkey)
    keys = [pubkey] if pubkey else []
    try:
        user = reg.add_user(
            registry,
            name=args.name,
            seq=args.seq,
            domain=args.domain,
            role=args.role,
            ssh_public_keys=keys,
            enabled=True,
        )
    except reg.RegistryError as e:
        err(str(e))
        return 2

    ports = reg.get_ports(user["seq"], registry["ports"])
    _save_registry(registry)
    ok(f"added user {bold(args.name)} (seq={user['seq']})")
    print(f"  Hermes SSH : {ports['h_ssh']}  Web: {ports['h_web_start']}-{ports['h_web_end']}")
    print(f"  Claude SSH : {ports['c_ssh']}  Web: {ports['c_web_start']}-{ports['c_web_end']}")
    _render_and_report()

    if not args.no_start:
        if not compose.docker_compose_available():
            warn("docker compose not available, skipping start")
            return 0
        info(f"starting {args.name}...")
        rc = compose.up_user(args.name, BASE_YML, RENDERED_DIR)
        if rc != 0:
            err(f"failed to start {args.name} (rc={rc})")
            return rc
        ok(f"{args.name} started")
    return 0


def cmd_add_bulk(args: argparse.Namespace) -> int:
    path = Path(args.csv_file)
    if not path.exists():
        err(f"CSV file not found: {path}")
        return 2

    registry = _load_registry()
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({k.strip(): (v or "").strip() for k, v in row.items()})

    added: list[str] = []
    failed: list[tuple[str, str]] = []
    for row in rows:
        name = row.get("name") or ""
        if not name:
            failed.append(("<no-name>", "missing name column"))
            continue
        try:
            pubkey = _read_pubkey(row.get("pubkey"))
            seq_raw = row.get("seq")
            seq_val = int(seq_raw) if seq_raw else None
            reg.add_user(
                registry,
                name=name,
                seq=seq_val,
                domain=row.get("domain") or "engineering",
                role=row.get("role") or "engineer",
                ssh_public_keys=[pubkey] if pubkey else [],
                enabled=True,
            )
            added.append(name)
        except (reg.RegistryError, ValueError) as e:
            failed.append((name, str(e)))

    if added:
        _save_registry(registry)
        _render_and_report()
        ok(f"added {len(added)} user(s): {', '.join(added)}")

    for name, reason in failed:
        err(f"skipped {name}: {reason}")

    if not args.no_start and added:
        if not compose.docker_compose_available():
            warn("docker compose not available, skipping start")
            return 0 if not failed else 1

        parallel = max(1, min(args.parallel, len(added)))
        info(f"starting {len(added)} user(s) with parallel={parallel}...")
        errors = 0
        with ThreadPoolExecutor(max_workers=parallel) as pool:
            futs = {
                pool.submit(compose.up_user, n, BASE_YML, RENDERED_DIR): n
                for n in added
            }
            for fut in as_completed(futs):
                name = futs[fut]
                try:
                    rc = fut.result()
                    if rc == 0:
                        ok(f"{name} started")
                    else:
                        err(f"{name} failed (rc={rc})")
                        errors += 1
                except Exception as e:
                    err(f"{name} raised: {e}")
                    errors += 1
        if errors:
            return 1
    return 0 if not failed else 1


def cmd_remove(args: argparse.Namespace) -> int:
    registry = _load_registry()
    user = reg.get_user(registry, args.name)
    if user is None:
        err(f"user '{args.name}' not found")
        return 2

    if compose.docker_compose_available():
        info(f"stopping {args.name}...")
        compose.down_user(args.name, BASE_YML, RENDERED_DIR, volumes=args.purge)
    else:
        warn("docker compose not available, only updating registry")

    reg.remove_user(registry, args.name)
    _save_registry(registry)

    rendered = RENDERED_DIR / f"user.{args.name}.yml"
    if rendered.exists():
        rendered.unlink()

    ok(f"removed user {args.name}")
    if args.purge:
        warn("volumes purged (data deleted)")
    _render_and_report()
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    registry = _load_registry()
    pubkey = _read_pubkey(args.pubkey)
    enabled_flag: bool | None = None
    if args.enable:
        enabled_flag = True
    if args.disable:
        enabled_flag = False
    try:
        reg.update_user(
            registry,
            args.name,
            domain=args.domain,
            role=args.role,
            add_pubkey=pubkey,
            enabled=enabled_flag,
        )
    except reg.RegistryError as e:
        err(str(e))
        return 2
    _save_registry(registry)
    ok(f"updated user {args.name}")
    _render_and_report()
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    registry = _load_registry()
    users = reg.list_users(registry)
    ports_cfg = registry["ports"]

    rows = []
    for u in users:
        p = reg.get_ports(u["seq"], ports_cfg)
        row: dict[str, Any] = {
            "name": u["name"],
            "seq": u["seq"],
            "domain": u.get("domain", ""),
            "role": u.get("role", ""),
            "enabled": u.get("enabled", True),
        }
        if args.ports:
            row["hermes_ssh"] = p["h_ssh"]
            row["hermes_web"] = f"{p['h_web_start']}-{p['h_web_end']}"
            row["claude_ssh"] = p["c_ssh"]
            row["claude_web"] = f"{p['c_web_start']}-{p['c_web_end']}"
        if args.status:
            row["hermes_state"] = compose.container_status(f"hermes-{u['name']}")
            row["claude_state"] = compose.container_status(f"claude-{u['name']}")
        rows.append(row)

    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 0

    if not rows:
        info("no users registered")
        return 0

    headers = ["NAME", "SEQ", "DOMAIN", "ROLE", "ENABLED"]
    if args.ports:
        headers += ["HERMES-SSH", "HERMES-WEB", "CLAUDE-SSH", "CLAUDE-WEB"]
    if args.status:
        headers += ["HERMES", "CLAUDE"]

    lines = []
    for r in rows:
        enabled_str = green("yes") if r["enabled"] else dim("no")
        line = [r["name"], str(r["seq"]), r["domain"], r["role"], enabled_str]
        if args.ports:
            line += [
                str(r["hermes_ssh"]), r["hermes_web"],
                str(r["claude_ssh"]), r["claude_web"],
            ]
        if args.status:
            line += [_colored_state(r["hermes_state"]), _colored_state(r["claude_state"])]
        lines.append(line)

    _print_table(headers, lines)
    return 0


def _colored_state(s: str) -> str:
    if s == "running":
        return green(s)
    if s in ("exited", "dead"):
        return red(s)
    if s == "absent":
        return dim(s)
    return yellow(s)


def _visible_len(s: str) -> int:
    import re
    return len(re.sub(r"\x1b\[[0-9;]*m", "", s))


def _print_table(headers: list[str], rows: list[list[str]]) -> None:
    widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            widths[i] = max(widths[i], _visible_len(cell))

    def pad(cell: str, w: int) -> str:
        return cell + " " * (w - _visible_len(cell))

    print("  ".join(bold(pad(h, widths[i])) for i, h in enumerate(headers)))
    for r in rows:
        print("  ".join(pad(cell, widths[i]) for i, cell in enumerate(r)))


def cmd_show(args: argparse.Namespace) -> int:
    registry = _load_registry()
    user = reg.get_user(registry, args.name)
    if user is None:
        err(f"user '{args.name}' not found")
        return 2
    ports = reg.get_ports(user["seq"], registry["ports"])
    resources = reg.get_effective_resources(user, registry["defaults"])
    print(bold(f"User: {user['name']}"))
    print(f"  seq        : {user['seq']}")
    print(f"  domain     : {user.get('domain', '')}")
    print(f"  role       : {user.get('role', '')}")
    print(f"  enabled    : {user.get('enabled', True)}")
    print(f"  ssh keys   : {len(user.get('ssh_public_keys', []))}")
    for k in user.get("ssh_public_keys", []):
        print(f"    - {k[:60]}...")
    print(bold("Ports"))
    print(f"  Hermes SSH : {ports['h_ssh']}")
    print(f"  Hermes Web : {ports['h_web_start']}-{ports['h_web_end']}")
    print(f"  Claude SSH : {ports['c_ssh']}")
    print(f"  Claude Web : {ports['c_web_start']}-{ports['c_web_end']}")
    print(bold("Resources"))
    print(f"  Hermes     : cpus={resources['hermes']['cpus']}, memory={resources['hermes']['memory']}")
    print(f"  Claude     : cpus={resources['claude']['cpus']}, memory={resources['claude']['memory']}")
    print(bold("Containers"))
    h_state = compose.container_status(f"hermes-{user['name']}")
    c_state = compose.container_status(f"claude-{user['name']}")
    print(f"  hermes-{user['name']:<12} : {_colored_state(h_state)}")
    print(f"  claude-{user['name']:<12} : {_colored_state(c_state)}")
    return 0


def cmd_start(args: argparse.Namespace) -> int:
    if args.name:
        registry = _load_registry()
        if reg.get_user(registry, args.name) is None:
            err(f"user '{args.name}' not found")
            return 2
        return compose.up_user(args.name, BASE_YML, RENDERED_DIR)
    return compose.up_all(BASE_YML, RENDERED_DIR)


def cmd_stop(args: argparse.Namespace) -> int:
    registry = _load_registry()
    if reg.get_user(registry, args.name) is None:
        err(f"user '{args.name}' not found")
        return 2
    return compose.down_user(args.name, BASE_YML, RENDERED_DIR, volumes=False)


def cmd_restart(args: argparse.Namespace) -> int:
    registry = _load_registry()
    if reg.get_user(registry, args.name) is None:
        err(f"user '{args.name}' not found")
        return 2
    return compose.restart_user(args.name, BASE_YML, RENDERED_DIR)


def cmd_ps(args: argparse.Namespace) -> int:
    return compose.ps(BASE_YML, RENDERED_DIR)


def cmd_logs(args: argparse.Namespace) -> int:
    registry = _load_registry()
    if reg.get_user(registry, args.name) is None:
        err(f"user '{args.name}' not found")
        return 2
    return compose.logs(args.name, BASE_YML, RENDERED_DIR, follow=args.follow, tail=args.tail)


def cmd_render(args: argparse.Namespace) -> int:
    try:
        files = render.render_all(REGISTRY_PATH, RENDERED_DIR)
    except reg.RegistryError as e:
        err(str(e))
        return 2
    ok(f"rendered {len(files)} compose fragment(s)")
    for f in files:
        print(f"  - {f.relative_to(PROJECT_ROOT)}")
    return 0


def cmd_health(args: argparse.Namespace) -> int:
    registry = _load_registry()
    names = [args.name] if args.name else [u["name"] for u in reg.list_users(registry)]
    rc = 0
    for name in names:
        user = reg.get_user(registry, name)
        if user is None:
            err(f"user '{name}' not found")
            rc = 2
            continue
        h_state = compose.container_status(f"hermes-{name}")
        c_state = compose.container_status(f"claude-{name}")
        ok_state = h_state == "running" and c_state == "running"
        status_str = green("OK") if ok_state else red("UNHEALTHY")
        print(f"  {name:<16} hermes={_colored_state(h_state)}  claude={_colored_state(c_state)}  {status_str}")
        if not ok_state:
            rc = 1
    return rc


def cmd_doctor(args: argparse.Namespace) -> int:
    failures = 0

    def check(label: str, condition: bool, detail: str = "") -> None:
        nonlocal failures
        if condition:
            print(f"  {green('✓')} {label}{' — ' + detail if detail else ''}")
        else:
            print(f"  {red('✗')} {label}{' — ' + detail if detail else ''}")
            failures += 1

    print(bold("Environment"))
    check("docker available", compose.docker_available())
    check("docker compose available", compose.docker_compose_available())

    print(bold("Files"))
    check("users/users.yaml exists", REGISTRY_PATH.exists(), str(REGISTRY_PATH))
    check("compose/base.yml exists", BASE_YML.exists(), str(BASE_YML))
    template = PROJECT_ROOT / "compose" / "templates" / "user.yml.j2"
    check("template exists", template.exists(), str(template))

    print(bold("Registry"))
    try:
        registry = _load_registry()
        users = registry.get("users", [])
        check("registry loads", True, f"{len(users)} user(s)")
        conflicts = reg.find_port_conflicts(registry)
        check("no port conflicts", not conflicts, "; ".join(conflicts) if conflicts else "")
    except reg.RegistryError as e:
        check("registry loads", False, str(e))

    print(bold("Rendered fragments"))
    try:
        files = render.render_all(REGISTRY_PATH, RENDERED_DIR)
        check("render succeeds", True, f"{len(files)} file(s)")
    except reg.RegistryError as e:
        check("render succeeds", False, str(e))

    if failures:
        err(f"{failures} check(s) failed")
        return 1
    ok("all checks passed")
    return 0


# --- parser ---
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="cluster", description="Hermes cluster management CLI")
    sub = p.add_subparsers(dest="command", required=True)

    ap = sub.add_parser("add", help="add a new user")
    ap.add_argument("name")
    ap.add_argument("--seq", type=int, default=None)
    ap.add_argument("--domain", default="engineering")
    ap.add_argument("--role", default="engineer")
    ap.add_argument("--pubkey", default=None, help="SSH public key string or path to file")
    ap.add_argument("--no-start", action="store_true")
    ap.set_defaults(func=cmd_add)

    ab = sub.add_parser("add-bulk", help="add users from CSV (columns: name,seq,domain,role,pubkey)")
    ab.add_argument("csv_file")
    ab.add_argument("--parallel", type=int, default=4)
    ab.add_argument("--no-start", action="store_true")
    ab.set_defaults(func=cmd_add_bulk)

    rm = sub.add_parser("remove", help="remove a user")
    rm.add_argument("name")
    rm.add_argument("--purge", action="store_true", help="also delete volumes")
    rm.set_defaults(func=cmd_remove)

    up = sub.add_parser("update", help="update user fields")
    up.add_argument("name")
    up.add_argument("--domain")
    up.add_argument("--role")
    up.add_argument("--pubkey", help="append SSH public key")
    up.add_argument("--enable", action="store_true")
    up.add_argument("--disable", action="store_true")
    up.set_defaults(func=cmd_update)

    ls = sub.add_parser("list", help="list users")
    ls.add_argument("--ports", action="store_true")
    ls.add_argument("--status", action="store_true")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(func=cmd_list)

    sh = sub.add_parser("show", help="show user details")
    sh.add_argument("name")
    sh.set_defaults(func=cmd_show)

    st = sub.add_parser("start", help="start a user (or all if omitted)")
    st.add_argument("name", nargs="?")
    st.set_defaults(func=cmd_start)

    sp = sub.add_parser("stop", help="stop a user")
    sp.add_argument("name")
    sp.set_defaults(func=cmd_stop)

    rs = sub.add_parser("restart", help="restart a user")
    rs.add_argument("name")
    rs.set_defaults(func=cmd_restart)

    ps = sub.add_parser("ps", help="show container status")
    ps.set_defaults(func=cmd_ps)

    lg = sub.add_parser("logs", help="show container logs")
    lg.add_argument("name")
    lg.add_argument("-f", "--follow", action="store_true")
    lg.add_argument("--tail", type=int, default=50)
    lg.set_defaults(func=cmd_logs)

    rd = sub.add_parser("render", help="render compose fragments from registry")
    rd.set_defaults(func=cmd_render)

    hl = sub.add_parser("health", help="check container health")
    hl.add_argument("name", nargs="?")
    hl.set_defaults(func=cmd_health)

    dr = sub.add_parser("doctor", help="diagnose setup")
    dr.set_defaults(func=cmd_doctor)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except reg.RegistryError as e:
        err(str(e))
        return 2
    except KeyboardInterrupt:
        err("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
