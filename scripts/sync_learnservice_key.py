#!/usr/bin/env python3
"""Align LearnService dev callers with the standalone LiteLLM master key."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STANDALONE_ENV = ROOT / ".env.litellm.dev"
READINESS_URL = "http://127.0.0.1:4000/health/readiness"


def read_env_value(path: Path, name: str) -> str:
    for line in path.read_text().splitlines():
        if line.startswith(f"{name}="):
            value = line.split("=", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if value:
                return value
    raise ValueError(f"{name} is missing or empty in {path}")


def update_master_key(path: Path, master_key: str) -> int:
    lines = path.read_text().splitlines()
    updated = 0
    for index, line in enumerate(lines):
        if line.startswith("LITELLM_MASTER_KEY="):
            lines[index] = f"LITELLM_MASTER_KEY={master_key}"
            updated += 1

    if updated == 0:
        lines.append(f"LITELLM_MASTER_KEY={master_key}")
        updated = 1

    fd, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as file:
            file.write("\n".join(lines) + "\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)
    return updated


def main() -> int:
    learn_service_dir = Path(
        sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Work" / "learn-service"
    ).expanduser().resolve()
    env_file = learn_service_dir / ".env"
    compose_file = learn_service_dir / "docker-compose.dev.yml"

    if not env_file.is_file() or not compose_file.is_file():
        print(f"LearnService dev .env/compose not found under {learn_service_dir}", file=sys.stderr)
        return 1

    try:
        master_key = read_env_value(STANDALONE_ENV, "LITELLM_MASTER_KEY")
        with urllib.request.urlopen(READINESS_URL, timeout=5) as response:
            readiness = response.read().decode()
        if response.status != 200 or '"db":"connected"' not in readiness:
            raise RuntimeError("standalone LiteLLM is not database-ready")
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Standalone LiteLLM check failed: {error}", file=sys.stderr)
        return 1

    try:
        updated = update_master_key(env_file, master_key)
    except OSError as error:
        print(f"Could not update {env_file}: {error}", file=sys.stderr)
        return 1

    command = [
        "docker",
        "compose",
        "--project-name",
        "learn-service",
        "--project-directory",
        str(learn_service_dir),
        "--env-file",
        str(env_file),
        "-f",
        str(compose_file),
        "up",
        "-d",
        "--no-deps",
        "--force-recreate",
        "learn_app_dev",
        "learn_worker_dev",
    ]
    try:
        subprocess.run(command, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        print(
            "The env file was synchronized, but LearnService containers could not be recreated. "
            "Rerun the command after fixing Docker Compose.",
            file=sys.stderr,
        )
        print(str(error), file=sys.stderr)
        return 1

    print(
        f"Synced {updated} LITELLM_MASTER_KEY entr{'y' if updated == 1 else 'ies'}; "
        "recreated only learn_app_dev and learn_worker_dev."
    )
    print("Secret values were not displayed; LearnService .env permissions are 0600.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
