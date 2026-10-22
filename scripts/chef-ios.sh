#!/bin/zsh
# Try a Chef cloud build of the iPhone app on Mike's phone. Chef's sandboxes can't compile iOS,
# so a build that touches App/ or Packages/ is only checked here: this fetches the build's commit
# from the `chef` remote into a throwaway worktree, builds and installs it with install-phone.sh
# (its App Store Connect key signs it, no Xcode account needed), and marks the run
# "compiled / installed" on its Ship card.
#
#   scripts/chef-ios.sh <runId|itemId>          Release, against prod: what the phone normally runs
#   CONFIG=Debug scripts/chef-ios.sh <run>      Debug, against dev
#   CONFIG=Debug PREVIEW=1 scripts/chef-ios.sh <run>
#                                               Debug, against the build's preview backend
#                                               (-ChefConvexURL); sign-in there needs test sign-in
#   PROD=1 scripts/chef-ios.sh <run>            a run from prod's Chef
#   BUILD_ONLY=1 scripts/chef-ios.sh <run>      build it, install nothing
#
# `npx chef ios <run>` (chef.ios in package.json) does the same with Xcode's own signing, which
# needs an Apple account signed in to Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
ref=${1:?usage: scripts/chef-ios.sh <runId|itemId>}
[[ "$ref" =~ '^[a-z0-9]{20,40}$' ]] || { echo "Not a run or request id: $ref"; exit 2; }
prod=()
[[ "${PROD:-0}" == 1 ]] && prod=(--prod)

info=$(npx convex run chef:chefIos "{\"ref\":\"$ref\"}" "${prod[@]}")
field() { print -r -- "$info" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s)[process.argv[1]];console.log(v??"")})' "$1"; }
branch=$(field branch); sha=$(field commitSha); preview=$(field previewConvexUrl)
[[ -n "$branch" && -n "$sha" ]] || { echo "That build has no commit yet ($(field status))"; exit 1; }
echo "Chef #$(field itemNumber): $(field title)"
echo "  $branch at ${sha:0:12}"

# Dev and prod each have their own repo; fetch from whichever remote is this deployment's.
info=$(npx convex run chef:chefSetupStatus '{}' "${prod[@]}")
url=$(field remoteUrl)
remote=$(git remote -v | awk -v u="$url" '$2 == u && $3 == "(fetch)" { print $1; exit }')
[[ -n "$remote" ]] || { echo "No git remote for $url: run \`npx chef init\` for this deployment"; exit 1; }
git fetch -q "$remote" "$branch"
tree=$(mktemp -d /tmp/poddle-chef-ios.XXXXXX)
trap 'git worktree remove --force "$tree" >/dev/null 2>&1 || true' EXIT
git worktree add -q --detach "$tree" "$sha"

args=()
[[ "${PREVIEW:-0}" == 1 && -n "$preview" ]] && args=(-ChefConvexURL "$preview")
report() { # <compiled> <installed> [error]
  local extra=""; [[ -n "${3:-}" ]] && extra=",\"error\":$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$3")"
  npx convex run chef:chefIos "{\"ref\":\"$ref\",\"report\":{\"compiled\":$1,\"installed\":$2,\"device\":\"MikeXS Max\"$extra}}" "${prod[@]}" >/dev/null
}
# This checkout's install-phone.sh, not the build's: nothing the agent wrote runs outside xcodebuild.
if SRC="$tree" LAUNCH_ARGS="${args[*]}" "$PWD/scripts/install-phone.sh"; then
  [[ "${BUILD_ONLY:-0}" == 1 ]] || report true true
else
  report false false "install-phone.sh failed"
  exit 1
fi
