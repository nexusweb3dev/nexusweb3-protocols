#!/usr/bin/env python3
"""Copy the v2 contract ABIs out of the forge build output into the package.

Usage:  python scripts/sync_abis.py [--out-dir path/to/forge/out]

Reads ``<repo>/out/<Contract>.sol/<Contract>.json`` (the forge artifact) and writes
``nexusweb3/abis/<Contract>.json`` containing only the ``abi`` array.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

CONTRACTS: tuple[str, ...] = (
    "AgentAccess",
    "AgentIdentityV2",
    "AgentReputationV2",
    "AgentKillSwitchV2",
    "AgentAuditLogV2",
    "FeeRouter",
    "AgentEscrowV2",
)

SDK_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FORGE_OUT = SDK_ROOT.parent.parent / "out"
ABI_DIR = SDK_ROOT / "nexusweb3" / "abis"


def _artifact_path(forge_out: Path, contract: str) -> Path:
    return forge_out / f"{contract}.sol" / f"{contract}.json"


def sync(forge_out: Path, abi_dir: Path) -> list[Path]:
    """Write one ``<Contract>.json`` per contract into ``abi_dir``. Returns written paths."""
    abi_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for contract in CONTRACTS:
        artifact = _artifact_path(forge_out, contract)
        if not artifact.is_file():
            raise FileNotFoundError(
                f"missing forge artifact {artifact}; run `forge build` in the repo root first"
            )
        try:
            data = json.loads(artifact.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"{artifact} is not valid JSON: {exc}") from exc
        abi = data.get("abi")
        if not isinstance(abi, list) or not abi:
            raise ValueError(f"{artifact} has no usable 'abi' field")
        target = abi_dir / f"{contract}.json"
        target.write_text(json.dumps(abi, indent=2) + "\n", encoding="utf-8")
        written.append(target)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sync v2 ABIs from forge output into the SDK.")
    parser.add_argument("--out-dir", default=str(DEFAULT_FORGE_OUT), help="forge `out` directory")
    args = parser.parse_args(argv)

    try:
        written = sync(Path(args.out_dir).resolve(), ABI_DIR)
    except (FileNotFoundError, ValueError) as exc:
        print(f"sync_abis: {exc}", file=sys.stderr)
        return 1

    for path in written:
        print(f"wrote {path.relative_to(SDK_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
