#!/usr/bin/env bash
set -euo pipefail

# Exercise deploy/aws/deploy.sh offline with a stubbed aws CLI and Terraform:
# the tfvars file is written on the first run, kept with the operator's edits
# on a rerun, and the init/apply/output flow runs in order.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The script resolves the example directory relative to itself, so give it a
# throwaway repository layout instead of the real one.
mkdir -p "$WORK/repo/deploy/aws" "$WORK/repo/terraform/examples/aws-ecs-postgres" "$WORK/bin"
cp "$SCRIPT_DIR/deploy.sh" "$WORK/repo/deploy/aws/deploy.sh"
EXAMPLE="$WORK/repo/terraform/examples/aws-ecs-postgres"

cat > "$WORK/bin/aws" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "configure get") exit 1 ;;
  *) echo "unexpected: aws $*" >&2; exit 1 ;;
esac
STUB
cat > "$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $*" >> "$TF_CALLS"
case "$1" in
  version) echo '{"terraform_version":"1.17.1"}' ;;
  init|apply) ;;
  output) case "${3:-}" in service_url) echo http://alb.example ;; setup_token) echo tok-123 ;; esac ;;
  *) echo "unexpected: terraform $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/"*

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

run() {
  : > "$WORK/calls"
  PATH="$WORK/bin:$PATH" TF_CALLS="$WORK/calls" AWS_REGION=eu-west-1 BIFROST_AUTO_APPROVE=1 \
    bash "$WORK/repo/deploy/aws/deploy.sh" > "$WORK/log" 2>&1
}

# 1. First run writes terraform.tfvars and drives init, apply, outputs.
if run; then
  grep -q '^region *= *"eu-west-1"' "$EXAMPLE/terraform.tfvars" || fail "first run: region missing from tfvars"
  grep -q '^image_repository *= *"maximhq/bifrost"' "$EXAMPLE/terraform.tfvars" || fail "first run: image_repository missing"
  grep -q '^terraform init -input=false$' "$WORK/calls" || fail "first run: init must run without -upgrade so the lock file pins providers"
  grep -q '^terraform apply -input=false -auto-approve' "$WORK/calls" || fail "first run: apply not auto-approved"
  grep -q 'tok-123' "$WORK/log" || fail "first run: setup token not printed"
else
  cat "$WORK/log" >&2; fail "first run: script exited non-zero"
fi

# 2. A rerun keeps an edited terraform.tfvars instead of overwriting it.
printf 'allowed_cidr = "203.0.113.0/24"\n' >> "$EXAMPLE/terraform.tfvars"
cp "$EXAMPLE/terraform.tfvars" "$WORK/tfvars.before"
if run; then
  cmp -s "$EXAMPLE/terraform.tfvars" "$WORK/tfvars.before" || fail "rerun: terraform.tfvars was rewritten, operator edits lost"
  grep -qi 'keeping existing' "$WORK/log" || fail "rerun: no notice that the existing tfvars is kept"
  grep -q '^terraform apply' "$WORK/calls" || fail "rerun: apply not called"
else
  cat "$WORK/log" >&2; fail "rerun: script exited non-zero"
fi

if [[ $FAILED -ne 0 ]]; then
  exit 1
fi
echo "PASS: deploy/aws/deploy.sh"
