#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  Scripts/audit-no-zig.sh --staged
  Scripts/audit-no-zig.sh --worktree
  Scripts/audit-no-zig.sh --range <git-range>

Audits staged changes or a committed range for Zig/kernel build surface.
BACKPORT-LEDGER.md and BACKPORT-TRIAGE.tsv may mention skipped Zig commits;
source, package, script, plugin, and test files may not reintroduce them.
EOF
}

mode="${1:---staged}"
range="${2:-}"

case "$mode" in
  --staged)
    name_cmd=(git diff --cached --name-only)
    diff_cmd=(git diff --cached --unified=0)
    ;;
  --worktree)
    name_cmd=(git diff --name-only)
    diff_cmd=(git diff --unified=0)
    ;;
  --range)
    if [ -z "$range" ]; then
      usage
      exit 2
    fi
    name_cmd=(git diff --name-only "$range")
    diff_cmd=(git diff --unified=0 "$range")
    ;;
  *)
    usage
    exit 2
    ;;
esac

bad_path_regex='(^Zig/|\.zig$|^Sources/COmniWMKernels/|^Plugins/OmniWMKernelsBuildPlugin/|^Sources/OmniWMIPC/ZigIPCSupport\.swift$|(^|/)KernelABI|build-zig-kernels|omniwm_kernels|check-kernel|check-kernels)'
allowed_record_regex='^(BACKPORT-LEDGER\.md|BACKPORT-TRIAGE\.tsv)$'
guardrail_script_regex='^Scripts/(audit-no-zig|classify-swift-backports)\.sh$'
bad_content_regex='(import COmniWMKernels|COmniWMKernels|omniwm_kernels|OmniWMKernelsBuildPlugin|build-zig-kernels|(^|[^A-Za-z0-9_])zig[[:space:]]+(build|run|test|fmt))'

bad_paths="$("${name_cmd[@]}" | grep -E "$bad_path_regex" || true)"

bad_content="$(
  "${diff_cmd[@]}" |
    awk -v allow="$allowed_record_regex" -v guardrail="$guardrail_script_regex" -v bad="$bad_content_regex" '
      /^diff --git / {
        path=$4
        sub(/^b\//, "", path)
        scan=(path !~ allow)
        next
      }
      scan && path ~ guardrail && /^\+/ && $0 !~ /^\+\+\+ / && $0 ~ bad {
        if ($0 ~ /(bad_path_regex=|bad_content_regex=|grep -Ei?q?|grep -Eq|rg -[A-Za-z]*q?|Zig\/|COmniWMKernels|omniwm_kernels)/) {
          next
        }
      }
      scan && /^\+/ && $0 !~ /^\+\+\+ / && $0 ~ bad {
        print path ":" $0
      }
    ' || true
)"

if [ -n "$bad_paths" ] || [ -n "$bad_content" ]; then
  echo "Rejected: Zig/kernel contamination detected." >&2
  if [ -n "$bad_paths" ]; then
    echo >&2
    echo "Bad paths:" >&2
    printf '%s\n' "$bad_paths" >&2
  fi
  if [ -n "$bad_content" ]; then
    echo >&2
    echo "Bad added content:" >&2
    printf '%s\n' "$bad_content" >&2
  fi
  exit 1
fi

echo "No Zig/kernel contamination detected."
