#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Usage: test-plan.sh <build.yml>. Runs the plan step for each event and checks the brands,
# then checks that ci-result runs on every run and only passes when all needed jobs succeeded.
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

# ci-result: a skipped required check counts as passed, so the job itself must never skip.
cond=$(yq '.jobs.ci-result.if' "$wf")
if [[ "$cond" == "always()" ]]; then echo "ok   ci-result if: $cond"; else echo "FAIL ci-result if: $cond, want always()"; fail=1; fi
yq '.jobs.ci-result.steps[0].run' "$wf" > "$dir/result.sh"
result() { # results expected
  if RESULTS=$1 bash "$dir/result.sh" >/dev/null; then got=pass; else got=fail; fi
  if [[ "$got" == "$2" ]]; then echo "ok   ci-result [$1] -> $got"; else echo "FAIL ci-result [$1] -> $got, want $2"; fail=1; fi
}
result "success success success" pass
result "success failure success" fail
result "success cancelled success" fail
result "success skipped success" fail
exit $fail
