#!/bin/zsh
# The "BDD pairing" hook in .threadbear/patches. Threadbear only runs a
# patch's automatic hooks when they're a single script path, so the script
# it trusted is exactly what runs (Threadbear docs/protocol.md, "Patches").
cd "$(dirname "$0")/.." || exit 1
npm run -s test:bdd-check
