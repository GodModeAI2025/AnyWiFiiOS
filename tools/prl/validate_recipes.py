#!/usr/bin/env python3
"""Prüft PRL-Recipes gegen Schemas/prl-v1.schema.json.

Ohne Argumente: Selbsttest der Fixtures (valid/ und invalid-policy/ müssen das Schema
bestehen, invalid-schema/ muss scheitern). Mit Dateipfaden: prüft genau diese Dateien,
z. B. ein von einem externen Agenten erzeugtes recipe.yaml aus einem Debug-Paket.

Benötigt: pip install pyyaml jsonschema
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / "Schemas" / "prl-v1.schema.json").read_text(encoding="utf-8"))
RECIPES = ROOT / "Packages" / "CaptiveCore" / "Tests" / "Fixtures" / "recipes"
VALIDATOR = Draft202012Validator(SCHEMA)


def errors(path: Path) -> list[str]:
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return [f"YAML: {exc}"]
    return [f"{'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}" for e in VALIDATOR.iter_errors(doc)]


def main(argv: list[str]) -> int:
    Draft202012Validator.check_schema(SCHEMA)
    failed = False
    if argv:
        for arg in argv:
            errs = errors(Path(arg))
            print(f"{'OK  ' if not errs else 'FAIL'} {arg}")
            for e in errs:
                print(f"     {e}")
            failed |= bool(errs)
        return 1 if failed else 0
    for group, should_pass in (("valid", True), ("invalid-policy", True), ("invalid-schema", False)):
        for path in sorted((RECIPES / group).glob("*.yaml")):
            errs = errors(path)
            ok = (not errs) == should_pass
            failed |= not ok
            detail = "" if should_pass else f"  ({errs[0][:90]})" if errs else "  (unerwartet gültig!)"
            print(f"{'OK  ' if ok else 'FAIL'} {group}/{path.name}{detail}")
            if should_pass and errs:
                for e in errs:
                    print(f"     {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
