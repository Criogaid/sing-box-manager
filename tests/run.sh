#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$project"
test_storage=$(mktemp -d)
trap 'rm -rf -- "$test_storage"' EXIT
export XDG_DATA_HOME=$test_storage/data XDG_CONFIG_HOME=$test_storage/config
for script in sb install.sh lib/*.sh tests/*.sh; do bash -n "$script"; done
for test in cli documents frontend forms nodes host; do
    printf '\nRunning %s\n' "$test"
    bash "tests/$test.sh"
done
if [[ -n ${TEST_CORE:-} && -n ${TEST_CADDY:-} ]]; then
    bash tests/integration.sh
fi
