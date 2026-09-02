#!/usr/bin/env bash
# Regenerates supabase/schema.sql — the public schema exactly as the
# migrations build it (local stack, never the linked project). Run it after
# adding a migration; the CI `backend` job diffs the committed file against
# a fresh build and fails when the snapshot is stale.
set -euo pipefail
cd "$(dirname "$0")/.."
supabase start >/dev/null
supabase db reset
supabase db dump --local --schema public -f supabase/schema.sql
echo "supabase/schema.sql regenerated"
