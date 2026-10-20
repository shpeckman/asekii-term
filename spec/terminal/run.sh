#!/usr/bin/env bash
# spec/terminal/run.sh
set -uo pipefail

cd "$(dirname "$0")/../.."

VARIANTS=("default:" "execution_context:-Dexecution_context" "release:--release")
SEEDS="${SEEDS:-5}"
REPEATS="${REPEATS:-3}"
LIMIT="${LIMIT:-300}"
ONLY="${ONLY:-}"
BUILD="$(mktemp -d)"
LOG="$BUILD/log"
FAILED=()
RUNS=0

trap 'rm -rf "$BUILD"' EXIT

attempt() {
  local label="$1"
  shift
  RUNS=$((RUNS + 1))
  if timeout "$LIMIT" "$@" >"$LOG" 2>&1; then
    return 0
  fi
  local status=$?
  FAILED+=("$label (exit $status)")
  printf '\nFAIL %s (exit %s)\n' "$label" "$status"
  tail -n 25 "$LOG"
  return 1
}

locations() {
  local file
  for file in spec/terminal/*_spec.cr spec/render/*_spec.cr; do
    grep -nE '^[[:space:]]*it[[:space:]]+"' "$file" | cut -d: -f1 | sed "s|^|$file:|"
  done
}

suite() {
  local name="$1" flags="$2" binary="$BUILD/$1" seed round location
  printf '== %s\n' "$name"
  printf '   build\n'
  attempt "$name build" crystal build $flags -o "$binary" spec/terminal/*_spec.cr spec/render/*_spec.cr || return
  printf '   defined order x%s\n' "$REPEATS"
  for round in $(seq "$REPEATS"); do
    attempt "$name defined order #$round" "$binary"
  done
  printf '   random order x%s\n' "$SEEDS"
  for round in $(seq "$SEEDS"); do
    seed=$((RANDOM * 32768 + RANDOM))
    attempt "$name random order seed $seed" "$binary" --order "$seed"
  done
  printf '   isolated examples\n'
  while read -r location; do
    attempt "$name isolated $location" "$binary" --location "$location"
  done < <(locations)
}

for variant in "${VARIANTS[@]}"; do
  name="${variant%%:*}"
  [[ -z "$ONLY" || "$ONLY" == "$name" ]] && suite "$name" "${variant#*:}"
done

printf '\n%s runs, %s failed\n' "$RUNS" "${#FAILED[@]}"
if ((${#FAILED[@]} > 0)); then
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi