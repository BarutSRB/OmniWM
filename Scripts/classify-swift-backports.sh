#!/usr/bin/env bash
set -euo pipefail

base="${1:-6fde9b910a6dd531eeaf3892499729120ae75f49}"
head_ref="${2:-ea732a35960ab2a899ecef393a37582d103d093e}"

printf 'commit\tshort\tbucket\tsubject\tnotes\n'

git log --reverse --format='%H%x09%P%x09%s' "$base..$head_ref" |
while IFS=$'\t' read -r sha parents subject; do
  short="${sha:0:8}"
  parent_count=$(wc -w <<<"$parents" | tr -d ' ')
  paths="$(git diff-tree --no-commit-id --name-only -r "$sha")"
  notes=""

  case "$short" in
    6b39ba9e|de13d4cc|349247c7|8a48b368|5475c44a|74152463|bc881a67|cbe7cffb|b1848772|cbceeab7)
      bucket="direct-dry-run"
      ;;
    16ee0c44|a739e703|7b19fdad)
      bucket="swift-contextual"
      ;;
    4167c898|5fce6d94|301c9a72|4ab8c865)
      bucket="settings-final-state"
      ;;
    84f315df)
      bucket="mixed-investigate-only"
      notes="large mixed commit; extract only reproduced Swift-native fixes"
      ;;
    *)
      if [ "$parent_count" -gt 1 ] || grep -Eiq '^(release:|release |Merge pull request|Docs update|README:|Add .*Contributors|Add .*Sponsors|Fix typo)' <<<"$subject"; then
        bucket="merge-release-doc-skip"
      elif grep -Eiq '(to Zig|into Zig|Zig kernel|Zig kernels|Finalize Zig|for zig|Zig validation|Zig cache)' <<<"$subject"; then
        bucket="zig-build-skip"
      elif grep -Eiq '(^Zig/|\.zig$|^Sources/COmniWMKernels/|^Plugins/OmniWMKernelsBuildPlugin/|^Sources/OmniWMIPC/ZigIPCSupport\.swift$|KernelABI|build-zig-kernels|omniwm_kernels|check-kernel|check-kernels)' <<<"$paths"; then
        if grep -Eq '^Sources/.*\.(swift|md)$' <<<"$paths"; then
          bucket="mixed-investigate-only"
        else
          bucket="zig-build-skip"
        fi
      elif git show --format= --unified=0 "$sha" |
        grep -Eiq '^[+-].*(import COmniWMKernels|COmniWMKernels|omniwm_kernels|OmniWMKernelsBuildPlugin|build-zig-kernels|(^|[^A-Za-z0-9_])zig[[:space:]]+(build|run|test|fmt))'; then
        bucket="zig-build-skip"
      else
        bucket="direct-dry-run"
        notes="auto-candidate; still requires dry-run and ledger"
      fi
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$short" "$bucket" "$subject" "$notes"
done
