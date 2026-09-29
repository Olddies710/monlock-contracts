#!/usr/bin/env bash
# Warning gate of the ci profile, compiled in groups.
#
# solc reports at most 256 warnings per run and silently drops the rest (warning 4591). Most of what it reports comes
# from lib/: Solady's deprecated `/// @solidity memory-safe-assembly` comments, which `ignored_warnings_from` hides but
# which still count towards the cap. Compiling the whole project at once crosses it, so a warning in our own code
# could be dropped unseen. Each group below stays under the cap and is built with warnings as errors; if a group ever
# crosses it, 4591 itself fails the gate, so nothing is ignored silently. Tests then run with FOUNDRY_DENY=never.
#
#   ./script/check-warnings.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export FOUNDRY_PROFILE=ci
shopt -s nullglob
groups=(
  "src"
  "script"
  "test/utils test/invariant"
  "$(echo test/*.t.sol)"
  "test/fork"
)
for group in "${groups[@]}"; do
  echo "==> forge build --force ${group}"
  # shellcheck disable=SC2086 # a group is a list of paths
  forge build --force ${group}
done
