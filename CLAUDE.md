# CLAUDE.md — http_connection_pool

## Project Goal

This gem provides a **portable, thread-safe, and Fiber-scheduler-aware HTTP
connection pool** built on top of `connection_pool` (>= 2.5.5, < 3) and
`concurrent-ruby`. The primary interface is the `Connectable` mixin: any class
or module that includes/extends it can send persistent HTTP requests through a
managed pool without touching sockets, mutexes, or keep-alive state directly.

The gem must remain usable outside Rails (no Rails runtime dependency). It is
verified to be compatible with Rails 7.2.x and Zeitwerk via test-only
dependencies.

---

## Non-Negotiable Design Principles

### 1. Thread safety and Fiber awareness
- All shared state (`Registry`, pool slots) must be safe under concurrent
  access — use `Concurrent::AtomicReference`, `Concurrent::AtomicBoolean`, and
  `Concurrent::Map` (lock-free). Never introduce a global `Mutex` on the hot
  path.
- Block forwarding in `with_connection` and `Pool#with` must use anonymous
  block pass (`&`) so the `connection_pool` gem can yield to a Fiber scheduler
  rather than parking the OS thread.
- New concurrent-ruby primitives must be required individually
  (`concurrent/atomic/atomic_boolean`, not `concurrent-ruby`) to keep load time
  and memory footprint minimal.

### 2. Security
- **Credential isolation** — pools are keyed by SHA-256 digest of
  `(origin, options)`. Two callers sharing a host but using different
  credentials each get their own pool. Never relax this.
- **No credential leakage** — `Pool#inspect`, `Pool#to_s`, `Pool#pretty_print`,
  and `Registry#inspect` must show only non-sensitive metadata (origin, pool
  size, closed state, option *keys*, pool count). They must never print option
  *values* (headers, auth tokens, SSL material).
- **URL validation** — `Registry#extract_origin` must reject non-http/https
  schemes and URLs with no host. The `SUPPORTED_SCHEMES` constant is the
  authoritative allowlist; do not accept arbitrary schemes.
- **Unbounded growth guard** — `max_pools` must remain available as an optional
  soft cap for registries that accept untrusted URLs. The PoolLimitError message
  must never include option values or digest keys.
- **bundler-audit** runs offline in the default `ci` task. A network-refreshing
  `rake audit` task also exists. Never remove the audit step from CI.
- `pool_key` must use `normalize_options` (deep-sort all hash keys by `to_s`)
  before hashing so that logically identical options in different key-insertion
  order always resolve to the same pool.

### 3. Performance
- `connection_pool` accessor in `ClassMethods` must be memoized in
  `@connection_pool` and re-validated only when the cached pool is closed.
  The hot path (`with_connection`) must not allocate per call.
- `PoolAccessors` readers (`base_url`, `pool_size`, etc.) walk the superclass
  chain and return on the first hit — no unbounded iteration.
- Targeted `concurrent-ruby` requires only; never `require 'concurrent-ruby'`.

### 4. Subclassing / Inheritance
- `PoolAccessors` readers walk the superclass chain so subclasses inherit
  `base_url`, `pool_size`, `pool_timeout`, and `pool_options` without restating
  them. A writer pins the value on the declaring class.
- A subclass with its own `pool_options` gets an isolated pool automatically
  (different digest → different key). A subclass with no overrides shares the
  parent's pool exactly.
- `pool_options` **replaces**, it does not merge. Document this clearly; provide
  an explicit merge recipe in README and code comments.
- `release_connection_pool` must pass `**pool_options` to `Registry#release` so
  it resolves the right digest key.

---

## Code Style

- **All non-interpolated strings use single quotes.**
- Every file begins with `# frozen_string_literal: true`.
- No top-level comments explaining *what* the code does — method and variable
  names carry that. Comments only for *why*: hidden constraints, surprising
  invariants, known workarounds.
- No multi-line docstrings or doc blocks except the existing module-level
  comment blocks in `Connectable`, which serve as usage examples.
- Prefer `attr_reader` over manually written getter methods.
- Keep methods short. `Metrics/MethodLength: Max: 20` is the enforced limit;
  aim for much less. Extract private methods rather than exceeding it.

---

## Documentation

- **Whenever a change affects behaviour, dependencies, requirements, or usage,
  update `README.md` AND every relevant Markdown file under `docs/` in the same
  change.** This is a standing instruction — do not wait to be asked. Historical
  records (e.g. completed plans under `docs/superpowers/plans/`) are not
  retroactively edited; update living docs only.
- **New project-specific skills go in `docs/skills/<name>/SKILL.md`; new
  project-specific subagents go in `docs/agents/<name>.md`.** See the README in
  each directory for the file conventions. Capture a workflow as a skill/agent
  rather than re-deriving it each session.
- Markdown follows standard best practices: one `#` H1 per file, sentence-case
  headings in nesting order (no skipped levels), fenced code blocks with a
  language tag, reference links over bare URLs in prose, tables for structured
  comparisons, and wrap prose at a sane width. Keep a blank line around headings,
  lists, and code fences.

---

## RuboCop

- Run `bundle exec rubocop -a` to auto-fix correctable offenses (e.g.
  `Performance/TimesMap`: `n.times.map` → `Array.new(n)`).
- Config lives in `.rubocop.yml`. Never skip a RuboCop check with an inline
  `# rubocop:disable` comment unless there is no other option — extract a
  method or restructure instead.
- Plugins declared with `plugins:` syntax (not `require:`):
  - `rubocop-performance`
  - `rubocop-rake`
  - `rubocop-rspec`
- `RSpec/DescribeClass` is excluded for `spec/integration/**/*` because those
  specs describe cross-cutting behaviour, not a single class.
- `bundle exec rubocop` must be clean before any commit. The `ci` Rake task
  enforces this.

---

## RSpec

- **Never use apostrophes in `it`/`describe`/`context` description strings** —
  `it 'uses parent's value'` is a Ruby `SyntaxError`. Use double quotes or
  rephrase: `it 'uses the parent class value'`.
- `spec_helper.rb` sets `mocks.verify_partial_doubles = true` — stubs on real
  objects (not doubles) are also verified against the actual method signature.
- The fake `HTTP::Client` is provided by the `'with a stubbed HTTP client'`
  shared context (`spec/support/stubbed_http_client.rb`), included globally in
  `spec_helper.rb`. It defines `let(:fake_client)` and stubs `HTTP.persistent`
  plus **both** `is_a?` and `kind_of?` for `HTTP::Client` — RSpec's `be_a`
  matcher uses `kind_of?`, not `is_a?`, and a missing stub fails silently. Do
  not re-stub these per file; add only test-specific stubs (e.g. `:get`) in a
  local `before`.
- **Helper methods/classes defined for specs go in a `spec/support` module,
  included into example groups by a matching tag** — never define them at the
  top level of a spec file (a top-level `class`/`def` leaks a global constant or
  pollutes the example-group namespace). Pattern: write `module FooHelpers` in
  `spec/support/foo_helpers.rb`, wire `config.include FooHelpers, :foo` in
  `spec_helper.rb`, then tag the group `:foo`. Existing examples:
  `ThreadSafetyHelpers` (`:thread_safety`, provides `cyclic_barrier`) and
  `FiberHelpers` (`:fiber`, provides `make_pool`/`close_created_pools`).
- `spec/support/**/*.rb` is auto-required by `spec_helper.rb`.
- Use `after do` (not `after(:each) do`) for teardown.
- `spec_helper.rb` resets the global registry in `config.after do` via
  `HttpConnectionPool::Registry.reset!` — every example starts with a clean
  singleton. Do not leak state between examples. Note `Registry.reset!` only
  touches the global singleton — locally constructed `Registry.new`/`Pool.new`
  objects must be closed by the example (use an `after` hook, e.g.
  `FiberHelpers#close_created_pools`).
- Integration specs live under `spec/integration/` and are tagged `:integration`.
  - `rails_compatibility_spec.rb` — verifies coexistence with `activesupport`
    7.2.x, shared-dep version overlap, and Connectable behaviour under
    Rails-style service objects.
  - `zeitwerk_compliance_spec.rb` — runs in a **clean subprocess** (`bundle exec
    ruby -e ...`) to exercise a real Zeitwerk eager-load. In-process checks are
    a no-op because `spec_helper` already required the gem.
- `RSpec/MultipleExpectations: Max: 3`, `RSpec/ExampleLength: Max: 20`.
- `Metrics/BlockLength` is excluded for `spec/**/*`.

---

## File / Constant Layout (Zeitwerk-conformant)

```
lib/
  http_connection_pool.rb            # entry point — require_relative only
  http_connection_pool/
    version.rb                       # defines VERSION (not Version — universal gem exception)
    pool.rb                          # HttpConnectionPool::Pool
    registry.rb                      # HttpConnectionPool::Registry
    connectable.rb                   # HttpConnectionPool::Connectable
                                     #   ::ClassMethods
                                     #   ::PoolAccessors
```

The gem loads itself via `require_relative` — it is invisible to a host Rails
app's Zeitwerk loader. The file/constant layout must remain Zeitwerk-conformant
regardless (verified by `spec/integration/zeitwerk_compliance_spec.rb`).

---

## Rake Tasks

| Task                  | What it does                                           |
| --------------------- | ------------------------------------------------------ |
| `rake` / `rake ci`    | `bundle:audit:check` (offline) → RuboCop → RSpec       |
| `rake audit`          | `bundle:audit:update` (network) → `bundle:audit:check` |
| `rake spec`           | RSpec only                                             |
| `rake rubocop`        | RuboCop only                                           |
| `rake bundle:audit:check` | Offline CVE scan                                  |

`rake ci` must always run clean before a PR. Never bypass bundler-audit.

---

## Runtime Dependencies (gemspec)

| Gem               | Constraint          | Why                                      |
| ----------------- | ------------------- | ---------------------------------------- |
| `http`            | `~> 6.0`            | Underlying HTTP client (llhttp C ext)    |
| `connection_pool` | `>= 2.5.5, < 3`     | `auto_reload_after_fork`, Fiber-aware    |
| `concurrent-ruby` | `~> 1.3`            | `AtomicReference`, `AtomicBoolean`, `Map`|

Rails (`activesupport`), `zeitwerk`, `rspec`, `rubocop`, and `bundler-audit`
are **development/test only** — never add them to `spec.add_dependency`.

---

## Error Classes

`Registry#stats` returns `Array<Hash>` (one entry per pool), not a Hash keyed
by origin. Each entry includes `:origin`, `:size`, `:checked_out`, `:idle`,
`:closed`.

| Class                              | When raised                                         |
| ---------------------------------- | --------------------------------------------------- |
| `Pool::TimeoutError`               | No connection available within `timeout`            |
| `Pool::ClosedError`                | `#with` called on a closed pool                     |
| `Registry::PoolLimitError`         | New pool would exceed `max_pools` cap               |

`OptionsMismatchError` was intentionally removed. Same-origin + different-options
is now a supported, non-error case handled by distinct digest keys.

---

## Fork Safety

`connection_pool >= 2.5` defaults `auto_reload_after_fork: true` and hooks
`Process._fork`. Workers automatically get fresh connections — no action needed
for correctness. App-server `after_fork`/`on_worker_boot` hooks should still
call `Registry.instance.close_all` for hygiene (clean slate, no defunct parent
connection objects).

---

## Key Decisions (do not reverse without discussion)

1. **SHA-256 keying over origin-only keying** — makes subclassing and
   multi-credential use safe without errors. `normalize_options` must deep-sort
   so insertion order is irrelevant.
2. **`pool_options` replaces, not merges** — simple, predictable, explicit. If
   merge semantics are needed, the caller does it; we don't infer intent.
3. **Soft `max_pools` cap** — a hard atomic cap would require a global lock and
   defeat `Concurrent::Map`. Brief overshoot under concurrency is documented and
   acceptable for a DoS backstop.
4. **No Rails runtime dependency** — the gem must work in plain Ruby, Sinatra,
   Hanami, etc. Rails compatibility is a test concern only.
5. **Subprocess for Zeitwerk spec** — in-process check is a no-op once
   `spec_helper` has required the gem. The subprocess is the only valid test.
