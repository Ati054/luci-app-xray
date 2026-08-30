#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import re
import subprocess

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-release.yml"


def resolve_bash() -> str:
    configured = os.environ.get("BASH_BIN")
    if configured:
        return configured
    if os.name == "nt":
        git_bash = pathlib.Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git/bin/bash.exe"
        if git_bash.is_file():
            return str(git_bash)
        raise AssertionError("Git for Windows bash.exe is required; WSL bash is not permitted")
    return "bash"


def iter_steps(document: dict) -> list[tuple[str, str]]:
    steps: list[tuple[str, str]] = []
    for job_name, job in document.get("jobs", {}).items():
        for index, step in enumerate(job.get("steps", []), start=1):
            if isinstance(step, dict) and isinstance(step.get("run"), str):
                label = str(step.get("name", f"step-{index}"))
                steps.append((f"{job_name}: {label}", step["run"]))
    return steps


def main() -> int:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    bash_bin = resolve_bash()
    steps = iter_steps(document)
    if not steps:
        raise AssertionError("workflow has no shell steps")

    expression = re.compile(r"\$\{\{.*?\}\}")
    for label, source in steps:
        parseable = expression.sub("ci_value", source)
        result = subprocess.run(
            [bash_bin, "-n"],
            input=parseable,
            text=True,
            encoding="utf-8",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            raise AssertionError(f"workflow shell syntax failed for {label}:\n{result.stderr}")
        print(f"PASS: workflow shell syntax: {label}")

    print(f"All {len(steps)} workflow shell blocks parsed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
