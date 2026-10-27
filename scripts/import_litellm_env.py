#!/usr/bin/env python3
"""Copy only provider env vars used by the local model config.

Values are read from a running legacy LiteLLM container and written to the
private local env file. Secret values are never printed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

PROVIDER_VARS = (
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "ELITELLM_API_KEY",
    "DASHSCOPE_API_KEY",
    "DASHSCOPE_API_BASE",
)


def read_container_environment(container: str) -> dict[str, str]:
    result = subprocess.run(
        [
            "docker",
            "inspect",
            "--format",
            "{{range .Config.Env}}{{println .}}{{end}}",
            container,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        name, separator, value = line.partition("=")
        if separator:
            values[name] = value
    return values


def update_env_file(path: Path, source: dict[str, str]) -> tuple[list[str], list[str]]:
    lines = path.read_text().splitlines() if path.exists() else []
    existing: dict[str, int] = {}
    for index, line in enumerate(lines):
        if line and not line.lstrip().startswith("#") and "=" in line:
            name = line.split("=", 1)[0]
            existing[name] = index

    copied: list[str] = []
    missing: list[str] = []
    for name in PROVIDER_VARS:
        value = source.get(name, "")
        if not value:
            missing.append(name)
            continue

        index = existing.get(name)
        if index is not None and lines[index].split("=", 1)[1]:
            continue  # Keep an explicitly configured local value.

        # JSON quoting keeps whitespace and comment characters in values safe
        # for Docker Compose's dotenv parser. Escape '$' from interpolation.
        encoded = json.dumps(value).replace("$", "$$")
        entry = f"{name}={encoded}"
        if index is None:
            lines.append(entry)
            existing[name] = len(lines) - 1
        else:
            lines[index] = entry
        copied.append(name)

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as temporary_file:
            temporary_file.write("\n".join(lines) + "\n")
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    return copied, missing


def main() -> int:
    container = sys.argv[1] if len(sys.argv) > 1 else "litellm_dev"
    env_file = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(".env.litellm.dev")
    try:
        source = read_container_environment(container)
    except (OSError, subprocess.CalledProcessError) as error:
        print(
            f"Не удалось прочитать env контейнера {container}; проверьте, что он запущен.",
            file=sys.stderr,
        )
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        return 1

    copied, missing = update_env_file(env_file, source)
    if copied:
        print(f"Скопированы переменные в {env_file}: {', '.join(copied)}")
    if missing:
        print(f"В исходном контейнере пусты/отсутствуют: {', '.join(missing)}")
    if not copied and not missing:
        print(f"Provider env уже настроен в {env_file}; существующие значения сохранены.")
    print("Значения не выводились; права на файл установлены в 0600.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
