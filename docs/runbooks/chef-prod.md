# Putting Chef live on prod

Prod is `coordinated-dodo-120` (Sydney). This sets up Chef there the way it's set up on dev: the board, cloud builds (Daytona, Code Storage, the AI gateway, billed to the `mikec` team), Mike as admin, and a "Ship it" deploy key for prod. Run everything from the repo root with this branch checked out. Commands with `--prod` hit prod. Nothing else here does.

Tested on dev (`striped-turtle-260`) on 22 Oct 2026:
- the setup;
- one cloud build of "Change the website footer text to 'Made with Poddle'": Ready in 8 min 54 s for $0.79 (45 model calls), with a preview at `fearless-robin-868.convex.site`, not shipped;
- a member's request from the simulator, which Mike rejected from the web panel.

## 0. Before you start

- Accounts (`accounts-prod.md`) and the website (`website-prod.md`) are live on prod. Mike's prod user exists.
- Merge this branch into `main` **with a merge commit or a fast-forward, not a squash**. Chef's repo on dev already has these commits as its `main`, and its deploy guard (`npm run dev` runs `chef guard` first) refuses any checkout that lacks them. If it was squashed anyway, run `git pull chef-dev main` (after step 2) or set `CHEF_SKIP_DEPLOY_GUARD=1` for dev.
- Back up: Dashboard > prod > Backups > Backup now.
- The vendored tarballs must still have the Sydney patch: `npm test -- tests/chef.test.ts` passes.

## 1. Mike's prod user id

```bash
npx convex data users --prod --limit 1000 --format jsonLines \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const l of s.split("\n")){try{const u=JSON.parse(l);if(u.email==="mike.cann@gmail.com"&&!u.mergedInto)console.log(u._id)}catch{}}})'
```

Use that id as `<mike>` below. It's different from dev's (`n1781n1qb0thwaqj09qfysjphd8grpw1`).

## 2. The git remote

The CLI always calls its remote `chef`, and dev's setup took that name (it's in the shared `.git/config`, so every worktree has it). Prod gets its own repo, so move dev's aside first:

```bash
git remote rename chef chef-dev
```

Its credential helper is keyed by URL, so `chef-dev` keeps working.

## 3. Set it up

```bash
npm run check
npx chef init --cloud --prod --admin <mike> --deploy-key --skip-beta
```

This is a production deploy (`npx convex deploy`): it installs the `feedback` and `chefCloud` components and adds `chef:*` and `/chef-agent/*`. There's no schema change to Poddle's own tables. Then it:
- creates prod's `poddle` repo on Code Storage, pushes HEAD as its `main`, and adds a `chef` remote for it;
- creates a preview deploy key (`CHEF_PREVIEW_DEPLOY_KEY` on prod) and checks the preview defaults it set from dev;
- names Mike admin;
- creates a deploy key for prod and records it (`CHEF_DEPLOY_KEY`), for "Ship it".

Expect it to end with "Cloud builds are off". Then check, names only:

```bash
npx chef status --prod
npx convex env list --prod --names-only
```

You want `adminUserId: <mike>`, `deployKeyPrefix: prod:coordinated-dodo-120`, `previewKeyPrefix: preview:mikec:poddle`, `repo: poddle`, `contract: 14`, and `siteUrl: true`. "Ship it" checks `PODDLE_SITE_URL` (`https://poddle.mikecann.app`), which the website rollout set.

## 4. Turn cloud builds on (Mike says yes first)

Each request Mike approves (and each of his own) is then built and billed: about $1 a build in model calls, capped at $20, plus sandbox time, a preview deployment and up to 2 warm snapshots.

```bash
npx convex run chef:chefEnableCloudBuilds '{}' --prod
npx chef status --prod      # cloud builds  on
```

## 5. The admin panel on the website

```bash
npm run web:upload:prod
```

Signed in at `https://poddle.mikecann.app/me`, Mike gets Chef's web panel: approvals, builds, "Ship it" with the diff. ChefKit's iOS sheet can't show the approval queue yet (README, "Chef").

## 6. The app

`scripts/install-phone.sh` (a Release build, against prod). Settings > Feedback > "Suggest a feature" opens Chef. Mike's sheet shows the Chef branding, his requests and their builds.

## 7. Dev afterwards

Dev keeps a working Chef for trying Chef itself. To stop it building:

```bash
npx convex run chef:chefDisableCloudBuilds '{"reason":"Chef runs on prod"}'
```

Dev's "Ship it" key still points at dev, so `npm run dev` stays guarded there: `git pull chef-dev main` if it refuses.

## After a ship

"Ship it" deploys the build to prod, uploads its website and moves the prod repo's `main`. Before the next deploy from your checkout, run `git pull chef main`. `npx convex deploy` from an older checkout would roll it back, and `npm run dev` refuses until you've pulled. The app isn't shipped this way. A build that changes `App/` or `Packages/` is tried with `PROD=1 scripts/chef-ios.sh <id>` and released from `main` as usual.

## Turning it off

```bash
npx convex run chef:chefDisableCloudBuilds '{"reason":"off"}' --prod
```

The board keeps working. The README has the full removal ("Turning it off" in Chef's `skills/convex-chef/SKILL.md`).
