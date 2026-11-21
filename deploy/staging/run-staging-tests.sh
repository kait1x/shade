#!/bin/bash
# Run packaged migration/rotation/rollback integration tests on the VPS staging.
set -euo pipefail
export PATH=/opt/node/bin:$PATH
STAMP=$(ls -1 /opt/shade-staging/releases | sort | tail -1)
echo "release: $STAMP"
cd "/opt/shade-staging/releases/$STAMP/server"
node --test --test-concurrency=1 test/migration-dryrun.test.mjs test/rsa-rotation.test.mjs test/rollback-journal.test.mjs