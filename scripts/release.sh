#!/bin/bash
# =============================================================================
# SyncTray local release — retired.
#
# Releases must be Developer ID signed and notarized: the Homebrew cask no longer
# strips the quarantine attribute, so an un-notarized app is blocked by Gatekeeper
# on every brew install. Only CI holds the signing + notary secrets, so releases
# are published by CI on merge to main (scripts/release-ci.sh, .github/workflows/ci.yml).
# =============================================================================
echo "✗ Local releases can't be notarized. Merge to main and CI publishes the release (scripts/release-ci.sh) — see docs/release-signing.md." >&2
exit 1
