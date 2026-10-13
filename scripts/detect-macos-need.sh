#!/usr/bin/env bash
# Decide whether a change needs the macOS arm64 checks.
#
# Usage: detect-macos-need.sh <base-revision> <head-revision>
#
# macOS runs only when a change touches behavior that can differ on macOS: a
# Zig file with a macOS, BSD, or Linux code path before or after the change,
# build.zig, the macOS signing script, or the macOS checks themselves. A Linux
# branch counts because macOS takes its other path. A Windows-only branch does
# not, because macOS and Linux share its other path. Set MACOS_REQUESTED to a
# reason to force the checks.
#
# Writes needed=true|false to $GITHUB_OUTPUT and the
# reasons to $GITHUB_STEP_SUMMARY when those files are set. Exits non-zero when
# either revision cannot be read, so the macOS check fails instead of passing
# without having looked at the change.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <base-revision> <head-revision>\n' "$0" >&2
  exit 2
fi

base="$1"
head="$2"

needed=false
reasons=()

require() {
  needed=true
  reasons+=("$1")
}

# Matches either side of the change, so removing a platform branch counts too.
has_platform_code() {
  local content
  content="$({ git show "$head:$1" 2>/dev/null; git show "$base:$1" 2>/dev/null; } || true)"
  grep -Eq "$2" <<<"$content"
}

zig_platform_code='\.linux([^A-Za-z0-9_]|$)|isBSD|\.macos|isDarwin|[Dd]arwin'

for revision in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$revision^{commit}" >/dev/null; then
    printf 'error: cannot read revision %s; the macOS check cannot decide\n' "$revision" >&2
    exit 1
  fi
done

if ! changed_files="$(git diff --name-only --no-renames "$base" "$head")"; then
  printf 'error: git diff %s %s failed; the macOS check cannot decide\n' "$base" "$head" >&2
  exit 1
fi

if [ -n "${MACOS_REQUESTED:-}" ]; then
  require "$MACOS_REQUESTED"
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .github/workflows/macos.yml | scripts/detect-macos-need.sh | scripts/smoke-binary.sh)
      require "$path: the macOS checks changed" ;;
    build.zig | build.zig.zon)
      require "$path: build configuration changed" ;;
    scripts/sign-and-notarize-macos.sh)
      require "$path: macOS signing changed" ;;
    *.zig)
      if has_platform_code "$path" "$zig_platform_code"; then
        require "$path: has a macOS or Linux code path"
      fi ;;
  esac
done <<<"$changed_files"

if [ "$needed" = true ]; then
  printf 'macOS arm64 checks needed:\n'
  printf '  %s\n' "${reasons[@]}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### macOS arm64 checks run\n\n'
      printf -- '- %s\n' "${reasons[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
else
  printf 'No macOS-specific change; macOS arm64 checks skipped.\n'
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'No macOS-specific change; macOS arm64 checks skipped.\n' >>"$GITHUB_STEP_SUMMARY"
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'needed=%s\n' "$needed" >>"$GITHUB_OUTPUT"
fi
