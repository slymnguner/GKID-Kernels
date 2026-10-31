#!/usr/bin/env python3

import json
import os
import sys
from typing import Dict, List, Any
from copy import deepcopy

# Default template
VALID_KSU = {"KSUN"}

DEFAULT = {
	"name": "Dummy",
	"KSU": "Dummy",
	"KSU_COMPAT": "false",
	"KSU_SUSFS": "false",
	"No_DS": "false"
}

def config(**overrides) -> Dict[str, Any]:
	"""Create config from default with overrides."""
	cfg = deepcopy(DEFAULT)
	cfg.update(overrides)
	if cfg["KSU"] not in VALID_KSU:
		raise ValueError(
			f"Unknown KSU='{cfg['KSU']}' in config '{cfg['name']}'. "
			f"Expected one of: {', '.join(sorted(VALID_KSU))}"
		)
	return cfg

# Build configurations
BUILD_CONFIGS: Dict[str, List[Dict[str, Any]]] = {
	"BUILD_KSUN": [
		config(name="KSUN", KSU="KSUN"),
		config(name="KSUN+SUSFS", KSU="KSUN", KSU_SUSFS="true"),
		config(name="Compat+KSUN", KSU="KSUN", KSU_COMPAT="true"),
		config(name="Compat+KSUN+SUSFS", KSU="KSUN", KSU_COMPAT="true", KSU_SUSFS="true"),
		config(name="Compat+NoDS+KSUN", KSU="KSUN", KSU_COMPAT="true", No_DS="true"),
		config(name="Compat+NoDS+KSUN+SUSFS", KSU="KSUN", KSU_COMPAT="true", KSU_SUSFS="true", No_DS="true")
	]
}

ALL_KERNEL_VERSIONS: List[str] = ["6.1"]

def get_env_bool(var_name: str, default: bool = False) -> bool:
	"""Read environment variable as boolean."""
	value = os.environ.get(var_name, "").strip().lower()
	if not value:
		return default
	return value in ("true", "1", "yes", "on")

def resolve_kernel_versions() -> List[str]:
	selected = os.environ.get("KERNEL_VERSION", "All").strip()

	if not selected or selected.lower() == "all":
		return ALL_KERNEL_VERSIONS

	if selected not in ALL_KERNEL_VERSIONS:
		raise ValueError(
			f"Unknown KERNEL_VERSION='{selected}'. "
			f"Expected 'All' or one of: {', '.join(ALL_KERNEL_VERSIONS)}"
		)

	return [selected]

def generate_matrix() -> Dict[str, List[Dict[str, Any]]]:
	variant_entries = []

	for env_var, configs in BUILD_CONFIGS.items():
		if get_env_bool(env_var):
			variant_entries.extend(configs)

			# Warn on unknown BUILD_* flags that are set to true
			for env_name in os.environ:
				if env_name.startswith("BUILD_") and env_name not in BUILD_CONFIGS:
					if get_env_bool(env_name):
						print(
							f"::warning::Unknown build flag {env_name}=true (ignored)",
							file=sys.stderr,
						)

	if not variant_entries:
		raise ValueError(
			"No build configurations selected! "
			"Set at least one BUILD_* environment variable to 'true'."
		)

	kernel_versions = resolve_kernel_versions()

	entries = []
	for kernel_version in kernel_versions:
		for variant in variant_entries:
			entry = deepcopy(variant)
			entry["kernel_version"] = kernel_version
			entry["name"] = f"{kernel_version}-{entry['name']}"
			entries.append(entry)

	return {"include": entries}

def main() -> None:
	try:
		matrix = generate_matrix()
		print(f"matrix={json.dumps(matrix)}")

		print(f"::notice::Generated {len(matrix['include'])} build configurations", file=sys.stderr)

	except Exception as e:
		print(f"::error::Failed to generate matrix: {str(e)}", file=sys.stderr)
		sys.exit(1)

if __name__ == "__main__":
	main()
