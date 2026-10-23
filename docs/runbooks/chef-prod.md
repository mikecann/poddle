# Chef on prod

Prod is `coordinated-dodo-120` (Sydney). Chef there is the feedback board alone: requests, voting and Mike's approvals, with Mike as admin. Cloud builds were taken out on 23 Oct 2026 (`docs/decisions.md`). Run everything from the repo root. Commands with `--prod` hit prod. Nothing else here does.

## Taking cloud builds off a deployment (once, 23 Oct 2026)

Prod and dev were set up with cloud builds (`npx chef init --cloud`) on 22 Oct. Do this on prod, then on dev without `--prod`.

### 1. Before the deploy

`chef:chefDisableCloudBuilds` goes with the cloud-build code, so run it while the old functions are still there. It revokes Chef's cloud and worker keys, which tells the panel and ChefKit that builds are off, and cleans up a build in flight:

```bash
npx convex run chef:chefDisableCloudBuilds '{"reason":"cloud builds removed","workers":true}' --prod
npx chef status --prod      # cloud builds off, worker keys 0, no build running
```

Back up too: Dashboard > prod > Backups > Backup now.

### 2. The deploy

```bash
npm run check
npx convex deploy
```

It removes the cloud-build component, the `chef:chef*` cloud functions (all but `chefSetAdmin` and `chefMigrateAgentKeys`) and the `/chef-agent/*` routes. The `feedback` component and its requests, votes, approvals and old build history stay. There's no schema change to Poddle's own tables. The cloud-build component's tables go with it, along with those of the components it brought (sandboxes, the repo mirror, build emails, workflows). They hold build bookkeeping only, and the board reads none of them.

### 3. After

Remove the env vars only cloud builds used, by name:

```bash
npx convex env remove CHEF_DEPLOY_KEY --prod
npx convex env remove CHEF_PREVIEW_DEPLOY_KEY --prod
npx convex env list --prod --names-only     # no CHEF_* left
```

Then the git remotes for the build repos (they're in the shared `.git/config`, so once is enough for every worktree): `git remote remove chef` and `git remote remove chef-dev`.

Removing the component doesn't delete what builds made outside the deployment: the build repos behind those remotes, any warm snapshots, and preview deployments (Dashboard > Poddle > the preview deployments, e.g. dev's test build `fearless-robin-868`). Delete the previews from the dashboard if they're still there.

## Setting Chef up on a fresh deployment

```bash
npx chef init --no-cloud --prod --admin <mike>
```

`<mike>` is Mike's user id on that deployment:

```bash
npx convex data users --prod --limit 1000 --format jsonLines \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const l of s.split("\n")){try{const u=JSON.parse(l);if(u.email==="mike.cann@gmail.com"&&!u.mergedInto)console.log(u._id)}catch{}}})'
```

Naming the admin again on its own: `npx convex run chef:chefSetAdmin '{"userId":"<mike>"}' --prod`.

## The admin panel on the website

```bash
npm run web:upload:prod
```

Signed in at `https://poddle.mikecann.app/me`, Mike gets Chef's web panel: the requests and the approval queue. It says "Cloud builds are off" next to approved requests, which is right. ChefKit's iOS sheet can't show the approval queue yet (README, "Chef").

## The app

`scripts/install-phone.sh` (a Release build, against prod). Settings > Feedback > "Suggest a feature" opens Chef. Mike's sheet shows the Chef branding and his requests.

## Taking Chef out entirely

Remove the panel mount (`ChefAdminPanel`), `convex/chef.ts`, `app.use(feedback)` and the vendored package. The requests and votes live in the `feedback` component, so that deploy deletes them: ask Mike first.
