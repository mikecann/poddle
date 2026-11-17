# State machines

Generated from each machine's rules by `npm run machines:diagrams`, and checked by `npm test` (`tests/stateMachines.test.ts`). Don't edit it by hand. The live version, with real rows in each state, is the website's admin Machines page (`/admin/machines`, Chef's admin only).

The rules live in `convex/lifecycles/`, and every machine is in the catalog in `convex/machines.ts`. Under each state are its own data fields. `[*] -->` is how a row is born and `--> [*]` marks a final state. Each event says who sends it: `(server)` for internal code, or its timer. The notes and the list under each diagram are the rules' own descriptions.

## Every machine

```mermaid
flowchart LR
  feedFetch["feedFetch<br/>feedFetches.state"]
  importBatch["importBatch<br/>importBatches.state"]
  importShow["importShow<br/>importQueue.state"]
```

## `feedFetch`, on `feedFetches.state`

Whether a show's feed is being fetched right now, so one feed is never fetched twice at once, and only the fetch holding the claim records how it went.

```mermaid
stateDiagram-v2
  direction LR
  state "idle" as idle
  note right of idle
No fetch of this feed is running. The
next one to start claims it.
  end note
  state "fetching" as fetching
  fetching : until, startedAt
  note right of fetching
A fetch holds the feed until `until`, 5
minutes after it started. Any other
fetch that tries now is told the feed is
busy.
  end note
  [*] --> fetching : CLAIM(lease) (server) / claim
  idle --> fetching : CLAIM(lease) (server) / claim
  fetching --> fetching : CLAIM(lease) (server) [claimRanOut] / claim
  fetching --> idle : FINISHED(lease) (server) [holdsClaim] / release
```

How a row is born:

- `CLAIM(lease) (server)` → `fetching`. The first fetch of a feed (a new show, or one that was never fetched since claims moved here) claims it.

From `idle`:

- `CLAIM(lease) (server)` → `fetching`. A fetch starts: the poller's, a refresh, someone opening the show, or an import.

From `fetching`:

- `CLAIM(lease) (server)` [claimRanOut] stays put. The fetch holding it died or ran past its 5 minutes, so a new fetch takes the feed over. The old one's report will be refused.
- `FINISHED(lease) (server)` [holdsClaim] → `idle`. The fetch holding the claim has stored what it found (or its error), and lets the feed go.

## `importBatch`, on `importBatches.state`

One Overcast import, from reading the file to Up Next being seeded. It restarts itself when its worker stops, and ends once, as done or failed.

```mermaid
stateDiagram-v2
  direction LR
  state "parsing" as parsing
  note right of parsing
The file is being read: every show in it
is created or found, and its episodes
staged to match once its feed is in.
  end note
  state "fetching" as fetching
  fetching : worker, restarts
  note right of fetching
The worker is fetching each show's feed,
a few at a time, then matching each
show's staged episodes to it. `worker`
is which run of the chain owns it;
`restarts`, how many in a row haven't
got anywhere.
  end note
  state "done" as done
  done : finishedAt
  note right of done
The import finished. Its counts are the
receipt the app shows.
  end note
  state "failed" as failed
  failed : finishedAt, error
  note right of failed
The import stopped, with the reason the
app shows. Its scratch rows are cleared
away.
  end note
  [*] --> parsing : START (server)
  parsing --> fetching : PARSED (server) / startWorker
  parsing --> failed : FAILED(error) (server) / fail
  parsing --> failed : READ_STALLED after 15 minutes / readStalled
  fetching --> fetching : CHECK after 5 minutes [1. madeProgress] / keepGoing
  fetching --> fetching : CHECK after 5 minutes [2. canRestart] / restartWorker
  fetching --> failed : CHECK after 5 minutes [else] / gaveUp
  fetching --> done : ALL_MATCHED (server) / finish
  done --> [*]
  failed --> [*]
```

How a row is born:

- `START (server)` → `parsing`. Someone uploads their Overcast export in the app (or a script does), and reading it starts.

From `parsing`:

- The clock sends `READ_STALLED` after 15 minutes. 15 minutes since reading began, longer than Convex lets the reading action run: it died.
- `PARSED (server)` → `fetching`. Every show is staged: the first run of the worker starts fetching their feeds.
- `FAILED(error) (server)` → `failed`. The file couldn't be read (not an OPML file, or the upload's gone).
- `READ_STALLED after 15 minutes` → `failed`. Reading stopped part way. The person is asked to import again.

From `fetching`:

- The clock sends `CHECK` after 5 minutes. Every 5 minutes while it's fetching: is it still getting somewhere?
- `CHECK after 5 minutes` [1. madeProgress] stays put. It got somewhere since the last check: carry on.
- `CHECK after 5 minutes` [2. canRestart] stays put. Nothing for 5 minutes, so its worker died: a new run starts where it stopped, and the old one stops at its next step.
- `CHECK after 5 minutes` [else] → `failed`. Three restarts in a row got nowhere. The person is asked to import again.
- `ALL_MATCHED (server)` → `done`. Every show is fetched and matched, and Up Next has been seeded in Overcast's order.

## `importShow`, on `importQueue.state`

One show in an Overcast import: its feed fetched, then the history staged for it matched to its episodes. It stays queued until that's done, so a worker that dies loses no shows.

```mermaid
stateDiagram-v2
  direction LR
  state "waiting" as waiting
  waiting : notBefore, busyCount
  note right of waiting
Waiting for a worker to fetch its feed,
not before `notBefore`. `busyCount`: how
often its feed was busy.
  end note
  state "fetching" as fetching
  fetching : claimedAt, busyCount
  note right of fetching
A worker run is fetching its feed, under
the claim it took at `claimedAt`.
  end note
  state "fetched" as fetched
  fetched : feedOk, oldestFeedPubDate?, medianDuration?, durations
  note right of fetched
Its feed is in. Once every show's is,
its staged episodes are matched to the
feed's, a page at a time.
  end note
  state "matched" as matched
  note right of matched
Done. Purged in the same step, so it's
only ever seen there.
  end note
  [*] --> waiting : QUEUED (server) / queue
  waiting --> fetching : CLAIM(claimedAt) (server) [due] / claim
  fetching --> fetching : CLAIM(claimedAt) (server) [claimStale] / claim
  fetching --> fetched : FETCHED(claimedAt, feedOk, oldestFeedPubDate?, medianDuration?, durations) (server) [holdsClaim] / fetched
  fetching --> waiting : BUSY(claimedAt, retryAt) (server) [1. canWait] / backOff
  fetching --> fetched : BUSY(claimedAt, retryAt) (server) [2. holdsClaim] / busyTooLong
  fetched --> matched : MATCHED (server)
  matched --> [*]
```

How a row is born:

- `QUEUED (server)` → `waiting`. Reading the export staged this show's episodes (or found them left without a row): it waits for a worker.

From `waiting`:

- `CLAIM(claimedAt) (server)` [due] → `fetching`. A worker run takes it and fetches its feed.

From `fetching`:

- `CLAIM(claimedAt) (server)` [claimStale] stays put. The run that claimed it 3 minutes ago never reported (it died): a newer run takes it over.
- `FETCHED(claimedAt, feedOk, oldestFeedPubDate?, medianDuration?, durations) (server)` [holdsClaim] → `fetched`. Its feed is in (or failed for good): what matching needs is noted, and it waits its turn to match.
- `BUSY(claimedAt, retryAt) (server)` [1. canWait] → `waiting`. Something else is fetching the feed (the poller, someone adding the show), so its episodes may be half stored. It waits 30 seconds rather than match against them.
- `BUSY(claimedAt, retryAt) (server)` [2. holdsClaim] → `fetched`. The other fetch never finished: it's matched as a failed feed, its history kept as ghosts.

From `fetched`:

- `MATCHED (server)` → `matched`. Every staged episode has been applied. The row is purged straight after.
