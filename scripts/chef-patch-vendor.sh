#!/bin/zsh
# Patches the vendored Chef tarballs (vendor/) so cloud builds work on a deployment
# outside Convex's default region. Poddle's dev and prod are in Sydney, so their
# URLs are <name>.ap-southeast-2.convex.cloud and .convex.site, and Chef (at
# sethconvex/feedback-chef dc9056d4bfb5, and every branch up to 18 Oct) only
# accepts <name>.convex.cloud and <name>.convex.site:
#   - chef-cloud's launcher refuses the app's own site host, so every build fails
#     before it starts ("siteHost must be <deployment>.convex.site");
#   - feedback's deploymentFromCloudUrl can't name the deployment, so "Ship it"'s
#     deploy key can't be recorded (chefSetDeployKey).
# Preview deployments are made in the default region (<name>.convex.cloud), so
# nothing on the preview side needs it. Both edits only widen a host check to
# allow one region label. Re-run after packing a new Chef: it's a no-op on an
# already patched tarball, and drop it once Chef accepts regional URLs itself.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

patch_tgz() { # <tarball> <file in package> <perl substitution>
  local tgz=$1 file=$2 expr=$3 dir="$work/$(basename "$1" .tgz)"
  mkdir -p "$dir"
  tar -xzf "$tgz" -C "$dir"
  perl -0pi -e "$expr" "$dir/package/$file"
  # Then `npm install` records the new tarball's integrity in package-lock.json.
  (cd "$dir" && COPYFILE_DISABLE=1 tar -czf "$OLDPWD/$tgz" package)
}

patch_tgz vendor/convex-dev-chef-cloud-0.0.1.tgz dist/client/chefLauncher.js \
  's{const SITE_HOST = /\^\[a-z0-9-\]\+\\\.convex\\\.site\$/;}{const SITE_HOST = /^[a-z0-9-]+(\\.[a-z0-9-]+)?\\.convex\\.site\$/; // Poddle: regional deployments}'
patch_tgz vendor/convex-dev-feedback-0.0.1.tgz dist/chef/deployKey.js \
  's{/\^https:\\/\\/\(\[a-z0-9\]\[a-z0-9-\]\{0,63\}\)\\\.convex\\\.cloud\\/\?\$/}{/^https:\\/\\/([a-z0-9][a-z0-9-]{0,63})(?:\\.[a-z0-9-]+)?\\.convex\\.cloud\\/?\$/}'

for f in chef-cloud:dist/client/chefLauncher.js feedback:dist/chef/deployKey.js; do
  tar -xzOf "vendor/convex-dev-${f%%:*}-0.0.1.tgz" "package/${f#*:}" | grep -nE 'SITE_HOST = |convex\\.cloud\\/\?\$/' | sed "s#^#${f%%:*}: #"
done
