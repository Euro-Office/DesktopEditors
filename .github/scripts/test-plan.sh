#!/usr/bin/env bash
# Usage: test-plan.sh <build.yml>. Runs the plan step for each event and checks the brands.
set -euo pipefail
wf=$1; dir=$(mktemp -d)
yq '.jobs.plan.steps[0].run' "$wf" > "$dir/run.sh"
export BRANDS=$(yq '.jobs.plan.steps[0].env.BRANDS' "$wf")
mkdir "$dir/bin"; printf '#!/bin/sh\nprintf "%%s\\n" $LABELS\n' > "$dir/bin/gh"; chmod +x "$dir/bin/gh"
fail=0
check() { # event head_ref labels expected
  out=$(GITHUB_EVENT_NAME=$1 HEAD_REF=$2 LABELS=$3 PR=1 GITHUB_REPOSITORY=x/y GITHUB_OUTPUT=$dir/out PATH="$dir/bin:$PATH" bash "$dir/run.sh" >/dev/null && sed -n 's/^brands=//p' "$dir/out" | jq -r 'map(.name) | join(",")')
  rm -f "$dir/out"
  if [[ "$out" == "$4" ]]; then echo "ok   $1 ${2:--} [$3] -> $out"; else echo "FAIL $1 ${2:--} [$3] -> $out, want $4"; fail=1; fi
}
both=euro-office,nextcloud-office
check pull_request feat/x "" euro-office
check pull_request feat/x "bug enhancement" euro-office
check pull_request feat/x "bug full-build" $both
check pull_request feat/x "full-build-x" euro-office
check pull_request release/v9.3.9 "" $both
check pull_request renovate/vue "" $both
check pull_request chore/nightly-submodule-bump "" $both
check push "" "" $both
check workflow_dispatch "" "" $both
exit $fail
