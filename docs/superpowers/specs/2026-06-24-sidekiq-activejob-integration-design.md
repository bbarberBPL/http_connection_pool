# Sidekiq and Active Job integration coverage — design

## Goal

Add integration tests that exercise the `Connectable` pool inside background
jobs, verifying it behaves correctly under Sidekiq's worker thread model and
Active Job's serialization layer. Specifically watch for unexpected memory
bloat, connection leaks, and pool-identity surprises when the same pool is
driven by many sequential and concurrent jobs.

This is a **test-only** concern. No `lib/` behavior changes; no new runtime
dependencies. Sidekiq and Active Job join the `:test` group only, consistent
with the no-Rails-runtime-dependency principle (see CLAUDE.md).

## Dependencies (test group only)

Added to the `:test` group in `Gemfile`:

| Gem         | Constraint  | Why                                                  |
| ----------- | ----------- | ---------------------------------------------------- |
| `sidekiq`   | `~> 7.3`    | Background-job runtime; used via `Sidekiq::Testing`  |
| `activejob` | `~> 7.2.3`  | Matches the `activesupport ~> 7.2.3` pin; Rails jobs |

`activejob` pulls in `globalid`. A Gemfile comment will explain — like the
existing `activesupport`/`zeitwerk` comments — that these are test-only and
that Sidekiq runs in **inline testing mode (no Redis)**, so CI stays hermetic.

## Execution model

`Sidekiq::Testing.inline!` — jobs run synchronously in-process through
Sidekiq's worker/middleware code path, no Redis and no separate process. This
exercises the real serialization and worker dispatch without infrastructure,
matching how the existing specs stub the socket layer for hermetic CI.

All examples use the global `'with a stubbed HTTP client'` shared context, so
`HTTP.persistent` returns the fake client and no real sockets open. The
existing `spec_helper` hook resets `HttpConnectionPool::Registry` between
examples, so each example starts from a clean singleton.

## New spec: `spec/integration/background_job_spec.rb`

Tagged `:integration`. `RSpec/DescribeClass` is already excluded for
`spec/integration/**/*` (cross-cutting behavior, not one class).

Three job execution paths, each performing
`with_connection { |conn| conn.get('/x') }`:

1. **Bare `Sidekiq::Job`** — a class that `include Sidekiq::Job`.
2. **Active Job on the `:test` adapter** — an `ActiveJob::Base` subclass with
   `queue_adapter = :test`, driven via `perform_enqueued_jobs`.
3. **Active Job on the `:sidekiq` adapter** — `queue_adapter = :sidekiq`, the
   realistic Rails-on-Sidekiq stack, executed under `Sidekiq::Testing.inline!`.

Job classes are defined in a `spec/support` module included by a tag (per the
project convention — never top-level constants in a spec file). Likely
`spec/support/job_helpers.rb` providing the job classes and a
`drain_jobs(n)` / `perform_job` helper, wired via `config.include JobHelpers,
:background_jobs` and tagged on the group.

### Behavioral assertions

Because sockets are stubbed, behavior is expressed as **registry invariants**
(the same approach the memory-leak and thread-safety specs use). Assertions
follow the corrected thread-safety style — assert "returns a live `Pool` and
completes", never `pool.closed?` (a race can close a pool between acquire and
check).

- **Pool sharing across jobs** — drain N jobs against one origin, then assert
  `registry.stats.length == 1`. For concurrency, run jobs that each acquire a
  pool and assert every result `is_a?(HttpConnectionPool::Pool)` with a
  completion count equal to N and a non-pool count of 0 (no deadlock, none
  nil).
- **Credential isolation across job classes** — two job classes targeting the
  same host with different `pool_options` (e.g. different auth headers) produce
  two distinct pools with distinct SHA-256 digests; neither token bleeds into
  the other's pool.
- **Pool survives across invocations** — pool object identity is stable across
  sequential job runs: `HTTP.persistent` is received exactly once per origin,
  not once per job (proves the pool is reused, not rebuilt per job — the core
  bloat risk).
- **Exception path returns connection** — a job that raises mid-
  `with_connection` (Sidekiq inline re-raises) leaves `checked_out == 0`
  afterward. Loop the failing job and assert connections are not slowly leaked
  out of the pool.

### Leak / bloat invariant (CI-safe half)

After draining a batch of **2,000** jobs (enough to prove the count is flat,
not to stress memory):

- `ObjectSpace.each_object(HttpConnectionPool::Pool).count` does not climb with
  job count (force `GC.start` before sampling).
- `registry.stats.length` equals the number of **distinct origins**, not the
  job count.

The heavier 10k+ churn and RSS measurement lives in `bin/`, out of CI.

## New probe: `bin/job_memory_probe`

Mirrors `bin/benchmark`'s shape (standalone script, `$LOAD_PATH` unshift,
helper methods on a small class). Stubs `HTTP.persistent`, runs jobs inline
through a 10k+ churn loop, and samples before/after:

- `GC.stat(:heap_live_slots)`,
- process RSS (from `/proc/self/status` `VmRSS` on Linux),
- `registry.stats.length`.

Prints a delta table. RSS is noisy and GC-timing dependent, so it stays a
manual probe — never a spec assertion (the memory-leak-audit skill makes this
split explicit).

## Documentation

Per the standing CLAUDE.md instruction (update README + relevant docs/ in the
same change):

- README: extend the compatibility/testing notes to mention verified Sidekiq +
  Active Job coverage, and add `background_job_spec.rb` to the integration-spec
  list. The "Forking app servers" section already covers Sidekiq's thread
  model; cross-reference rather than duplicate.
- No `lib/` behavior change → no API/usage docs change.

## Out of scope

- Real Redis / a booted Sidekiq server process (rejected: adds a service
  dependency and flakiness for a gem test; inline mode exercises the relevant
  code path).
- Sidekiq retry/dead-set semantics beyond the single exception-path assertion.
- A full dummy Rails app (Combustion) — not needed; Active Job runs standalone.

## Verification

`bundle exec rake ci` (bundler-audit → RuboCop → RSpec) must stay green. The
new spec must pass deterministically across repeated runs (no flakiness from
the concurrency assertions).
