# Web server, status page and registry (`serve/`)

@README.md

- A build's duration counts from the line `lib/build-lock` logs once the build has the lock
  ("Build lock taken", found by `status-gen` with `journalctl --grep`): keep the two in line. Runs
  from before `lib/build-lock` have no such line and count from the unit's start. A running unit
  without the line is queued only if its loaded `ExecStart` uses `lib/build-lock`: a unit started
  before the `daemon-reload` that brought it in runs its old command and never logs it.
- A bootc build retried by `lib/retry-once` logs the line once per attempt and the last one counts:
  during the 30 min before the retry the duration still runs from the first attempt.
