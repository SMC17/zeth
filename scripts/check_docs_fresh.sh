#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "docs-check: $1" >&2
  exit 1
}

check_no_stale_markers() {
  local file="$1"
  local pattern="$2"
  if rg -n "$pattern" "$file" >/dev/null 2>&1; then
    echo "docs-check: stale marker found in $file"
    rg -n "$pattern" "$file"
    exit 1
  fi
}

check_archived_labeled() {
  local file="$1"
  if ! head -n 12 "$file" | rg -qi "archived"; then
    fail "missing archive label in $file"
  fi
}

canonical_docs=(
  "README.md"
  "STATUS_SUMMARY.md"
  "docs/ARCHITECTURE.md"
  "docs/architecture/EVM_PARITY_STATUS.md"
  "docs/architecture/TECHNICAL_EXCELLENCE.md"
)

# Canonical docs must not regress to old milestone language/metrics.
stale_pattern='January 2025|v0\.1\.0-alpha|14 tests passing|82/83|98\.8% Ethereum validated|Week [0-9]'
for doc in "${canonical_docs[@]}"; do
  [ -f "$doc" ] || fail "missing canonical doc: $doc"
  check_no_stale_markers "$doc" "$stale_pattern"
done

archived_docs=(
  "docs/architecture/PROJECT_STATUS.md"
  "docs/architecture/IMPLEMENTATION_STATUS.md"
  "docs/community/PROJECT_ROADMAP.md"
  "docs/community/ROADMAP.md"
  "docs/internal/CURRENT_STATUS.md"
  "docs/validation/KNOWN_ISSUES.md"
  "docs/validation/BUGS_FOUND.md"
  "docs/validation/REFERENCE_COMPARISON.md"
)

for doc in "${archived_docs[@]}"; do
  [ -f "$doc" ] || fail "missing archived doc: $doc"
  check_archived_labeled "$doc"
done

while IFS= read -r file; do
  check_archived_labeled "$file"
done < <(find docs/internal -type f -name '*.md' | sort)

echo "docs-check: ok"
