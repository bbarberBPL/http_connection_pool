# Sidekiq and Active Job Integration Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add test-only integration coverage proving the `Connectable` pool behaves correctly (no leaks, no bloat, correct sharing/isolation) inside Sidekiq and Active Job background jobs.

**Architecture:** Add `sidekiq` and `activejob` to the `:test` group. Run jobs through `Sidekiq::Testing.inline!` (no Redis) and Active Job's `:test`/`:sidekiq` adapters, with `HTTP.persistent` stubbed via the existing shared context so no real sockets open. Job classes live in a tagged `spec/support` helper module. Behavior is asserted as registry invariants (pool counts, object counts, checked-out counts). A separate `bin/job_memory_probe` does the heavier RSS/GC churn out of CI.

**Tech Stack:** Ruby (MRI), RSpec, Sidekiq 7.3, Active Job 7.2.3, connection_pool, concurrent-ruby.

## Global Constraints

- **MRI (CRuby) only.** Never add JRuby/TruffleRuby to any matrix.
- **No new runtime dependencies.** `sidekiq` and `activejob` go in the `:test` group of `Gemfile` only — never `spec.add_dependency` in the gemspec.
- **All non-interpolated strings use single quotes.** Every file begins with `# frozen_string_literal: true`.
- **No apostrophes in `it`/`describe`/`context` strings** — `it 'uses parent's value'` is a Ruby SyntaxError. Use double quotes or rephrase.
- **Helper methods/classes for specs go in a `spec/support` module included by a matching tag** — never define a top-level `class`/`def` in a spec file.
- **Never assert `pool.closed?` to prove liveness** — a race can close a pool between acquire and check. Assert `is_a?(HttpConnectionPool::Pool)` plus a completion count instead.
- **`bundle exec rake ci`** (bundler-audit → RuboCop → RSpec) must be clean before any commit. Run `bundle exec rubocop -a` to auto-fix correctable offenses.
- **Git:** never `git add -A`/`.`; add files by name. `Gemfile.lock` is gitignored — never stage it. Do not `git push` (user-only). End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Update README** in the same change (standing instruction): add the new spec to the integration-spec list and note Sidekiq/Active Job coverage.
- The global registry is reset between examples by `spec_helper`'s `config.after { HttpConnectionPool::Registry.reset! }`. Locally constructed registries/pools must be closed by the example.
- The `'with a stubbed HTTP client'` shared context is included globally: it provides `let(:fake_client)` (an `instance_double(HTTP::Client)`) and stubs `HTTP.persistent`, `is_a?`, and `kind_of?`. Add only test-specific stubs (e.g. `:get`) in a local `before`.

---

### Task 1: Add test dependencies and the job-helper support module

**Files:**
- Modify: `Gemfile` (add `sidekiq`, `activejob` to the `:test` group)
- Create: `spec/support/job_helpers.rb`
- Modify: `spec/spec_helper.rb` (wire `JobHelpers` include by `:background_jobs` tag)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `JobHelpers` module, included into groups tagged `:background_jobs`, providing:
    - `perform_active_job(job_class, *args)` — enqueues and runs an `ActiveJob::Base` subclass under the `:test` adapter via `perform_enqueued_jobs`.
    - `registry` — returns `HttpConnectionPool::Registry.instance`.
  - Sidekiq inline mode active for tagged examples (set in the support module's hooks).
  - `sidekiq`/`activejob` resolvable in the test bundle.

- [ ] **Step 1: Add the gems to the `:test` group**

In `Gemfile`, inside the existing `group :test do` block (which currently holds `activesupport`, `async`, `zeitwerk`), add:

```ruby
  # Background-job integration is verified at test time only — neither Sidekiq
  # nor Active Job is a runtime dependency (the gem must stay usable outside
  # Rails and outside any job framework). Sidekiq runs in inline testing mode
  # (Sidekiq::Testing.inline!), so CI needs no Redis service. activejob is
  # pinned to the same 7.2.x series as activesupport above and drags in globalid.
  gem 'sidekiq',  '~> 7.3'
  gem 'activejob', '~> 7.2.3'
```

- [ ] **Step 2: Install and confirm resolution**

Run: `bundle install`
Expected: resolves cleanly; `sidekiq` and `activejob` (and `globalid`) appear. Do NOT stage `Gemfile.lock` (gitignored).

Run: `bundle exec ruby -e "require 'sidekiq'; require 'active_job'; puts Sidekiq::VERSION; puts ActiveJob::VERSION::STRING"`
Expected: prints a 7.3.x Sidekiq version and a 7.2.x Active Job version.

- [ ] **Step 3: Create the job-helper support module**

Create `spec/support/job_helpers.rb`:

```ruby
# frozen_string_literal: true

require 'sidekiq'
require 'sidekiq/testing'
require 'active_job'

# Helpers and job classes for the background-job integration spec. Included
# into any example group tagged :background_jobs (wired in spec_helper.rb).
#
# Sidekiq runs in inline mode for these examples: enqueuing a job executes it
# synchronously in-process, exercising Sidekiq's worker/middleware path without
# Redis. Active Job uses its :test adapter, drained explicitly so we control
# exactly when jobs run.
module JobHelpers
  def self.included(base)
    base.before do
      Sidekiq::Testing.inline!
      ActiveJob::Base.queue_adapter = :test
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      ActiveJob::Base.queue_adapter.performed_jobs.clear
    end

    base.after do
      Sidekiq::Testing.fake!
    end
  end

  def registry
    HttpConnectionPool::Registry.instance
  end

  # Enqueue and immediately run an ActiveJob::Base subclass under the :test
  # adapter. perform_enqueued_jobs makes enqueued jobs execute synchronously.
  def perform_active_job(job_class, *args)
    job_class.queue_adapter.perform_enqueued_jobs = true
    job_class.perform_later(*args)
  ensure
    job_class.queue_adapter.perform_enqueued_jobs = false
  end
end
```

- [ ] **Step 4: Wire the include in spec_helper**

In `spec/spec_helper.rb`, add to the `RSpec.configure` block alongside the existing `config.include` lines:

```ruby
  config.include JobHelpers, :background_jobs
```

- [ ] **Step 5: Verify the suite still loads (no regressions)**

Run: `bundle exec rspec --dry-run 2>&1 | tail -5`
Expected: no load errors; existing examples still enumerate.

- [ ] **Step 6: Run RuboCop on the new/changed files**

Run: `bundle exec rubocop spec/support/job_helpers.rb spec/spec_helper.rb Gemfile`
Expected: no offenses (run `bundle exec rubocop -a` first if any are correctable).

- [ ] **Step 7: Commit**

```bash
git add Gemfile spec/support/job_helpers.rb spec/spec_helper.rb
git commit -m "$(cat <<'EOF'
Add sidekiq/activejob test deps and job-helper support module

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Define the job classes and a smoke test (bare Sidekiq::Job + both Active Job adapters)

**Files:**
- Modify: `spec/support/job_helpers.rb` (add job classes)
- Create: `spec/integration/background_job_spec.rb`

**Interfaces:**
- Consumes: `JobHelpers` (Task 1), the `'with a stubbed HTTP client'` shared context (`fake_client`), `registry`.
- Produces (constants defined inside `JobHelpers`, so they are namespaced, not global):
  - `JobHelpers::PoolJob` — bare `Sidekiq::Job`; `perform(path = '/x')` does `PoolClient.with_connection { |c| c.get(path) }`.
  - `JobHelpers::PoolActiveJob` — `ActiveJob::Base`; same body.
  - `JobHelpers::SidekiqAdapterActiveJob` — `ActiveJob::Base` with `self.queue_adapter = :sidekiq`; same body.
  - `JobHelpers::PoolClient` — a `Connectable` class with `base_url = 'https://jobs.example.com'`.

- [ ] **Step 1: Write the failing smoke test**

Create `spec/integration/background_job_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

# Exercises the Connectable pool inside background jobs. Sockets are stubbed
# (HTTP.persistent returns fake_client), so behaviour is asserted as registry
# invariants: pool counts, object counts, and checked-out counts.
RSpec.describe 'Background job integration', :integration, :background_jobs do
  before { allow(fake_client).to receive(:get).and_return(:ok) }

  describe 'bare Sidekiq::Job' do
    it 'borrows a pooled connection when performed inline' do
      JobHelpers::PoolJob.perform_async('/status')
      expect(HTTP).to have_received(:persistent).with('https://jobs.example.com:443')
    end
  end

  describe 'Active Job on the :test adapter' do
    it 'borrows a pooled connection when performed' do
      perform_active_job(JobHelpers::PoolActiveJob, '/status')
      expect(HTTP).to have_received(:persistent).with('https://jobs.example.com:443')
    end
  end

  describe 'Active Job on the :sidekiq adapter' do
    it 'borrows a pooled connection when performed inline' do
      JobHelpers::SidekiqAdapterActiveJob.perform_later('/status')
      expect(HTTP).to have_received(:persistent).with('https://jobs.example.com:443')
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/integration/background_job_spec.rb`
Expected: FAIL — `NameError: uninitialized constant JobHelpers::PoolJob` (classes not defined yet).

- [ ] **Step 3: Define the job classes in the support module**

In `spec/support/job_helpers.rb`, add these constants inside `module JobHelpers` (after the `self.included` hook, before the instance methods):

```ruby
  class PoolClient
    include HttpConnectionPool::Connectable
    self.base_url  = 'https://jobs.example.com'
    self.pool_size = 5
  end

  class PoolJob
    include Sidekiq::Job
    def perform(path = '/x')
      PoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  class PoolActiveJob < ActiveJob::Base
    def perform(path = '/x')
      PoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  class SidekiqAdapterActiveJob < ActiveJob::Base
    self.queue_adapter = :sidekiq
    def perform(path = '/x')
      PoolClient.with_connection { |conn| conn.get(path) }
    end
  end
```

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `bundle exec rspec spec/integration/background_job_spec.rb`
Expected: PASS (3 examples).

Note: if `HTTP.persistent` is received with a different origin string, correct the expected origin to match what `Registry#extract_origin` produces for `https://jobs.example.com` (scheme + host + `:443`).

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop spec/support/job_helpers.rb spec/integration/background_job_spec.rb`
Expected: no offenses (auto-fix with `-a` if needed).

- [ ] **Step 6: Commit**

```bash
git add spec/support/job_helpers.rb spec/integration/background_job_spec.rb
git commit -m "$(cat <<'EOF'
Add job classes and smoke tests for sidekiq/activejob pool use

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Assert pool sharing across jobs and pool survival across invocations

**Files:**
- Modify: `spec/integration/background_job_spec.rb`

**Interfaces:**
- Consumes: `JobHelpers::PoolJob`, `JobHelpers::PoolClient`, `registry`, `fake_client`.
- Produces: nothing for later tasks (assertions only).

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `spec/integration/background_job_spec.rb`:

```ruby
  describe 'pool sharing and survival across jobs' do
    it 'shares one pool across many sequential jobs against the same origin' do
      50.times { JobHelpers::PoolJob.perform_async('/status') }
      expect(registry.stats.length).to eq(1)
    end

    it 'reuses the same pool rather than rebuilding it per job' do
      50.times { JobHelpers::PoolJob.perform_async('/status') }
      # One persistent client built per pooled connection, never one per job.
      expect(HTTP).to have_received(:persistent).at_most(JobHelpers::PoolClient.pool_size).times
    end

    it 'hands every concurrent job a live pool without deadlock' do
      returned = Concurrent::AtomicFixnum.new(0)
      non_pool = Concurrent::AtomicFixnum.new(0)

      threads = Array.new(20) do
        Thread.new do
          pool = JobHelpers::PoolClient.connection_pool
          pool.is_a?(HttpConnectionPool::Pool) ? returned.increment : non_pool.increment
        end
      end
      threads.each(&:join)

      expect(returned.value).to eq(20)
      expect(non_pool.value).to eq(0)
    end
  end
```

- [ ] **Step 2: Ensure the concurrent-ruby primitive is required**

`Concurrent::AtomicFixnum` must be loadable. Add to the top of `spec/integration/background_job_spec.rb`, after `require 'spec_helper'`:

```ruby
require 'concurrent/atomic/atomic_fixnum'
```

- [ ] **Step 3: Run the tests**

Run: `bundle exec rspec spec/integration/background_job_spec.rb -e 'pool sharing and survival'`
Expected: PASS (3 examples). If the `at_most` count fails, inspect `registry.stats` — a count above `pool_size` means a pool is being rebuilt per job (a real bloat finding to investigate, not a test to loosen).

- [ ] **Step 4: Run the full new spec file**

Run: `bundle exec rspec spec/integration/background_job_spec.rb`
Expected: all examples PASS.

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop spec/integration/background_job_spec.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add spec/integration/background_job_spec.rb
git commit -m "$(cat <<'EOF'
Assert pool sharing and reuse across background jobs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Assert credential isolation across job classes and exception-path connection return

**Files:**
- Modify: `spec/support/job_helpers.rb` (add a second client/job with distinct options, and a raising job)
- Modify: `spec/integration/background_job_spec.rb`

**Interfaces:**
- Consumes: existing `JobHelpers` constants, `registry`, `fake_client`.
- Produces (inside `JobHelpers`):
  - `JobHelpers::AltPoolClient` — `Connectable` class, same `base_url` as `PoolClient` but distinct `pool_options` (different auth header).
  - `JobHelpers::AltPoolJob` — bare `Sidekiq::Job` using `AltPoolClient`.
  - `JobHelpers::RaisingJob` — bare `Sidekiq::Job` whose block raises after checkout.

- [ ] **Step 1: Write the failing tests**

Add to `spec/integration/background_job_spec.rb`:

```ruby
  describe 'credential isolation across job classes' do
    it 'gives two job classes on the same host distinct pools' do
      JobHelpers::PoolJob.perform_async('/status')
      JobHelpers::AltPoolJob.perform_async('/status')

      expect(registry.stats.length).to eq(2)
    end

    it 'never shares a pool between the two job classes' do
      JobHelpers::PoolJob.perform_async('/status')
      JobHelpers::AltPoolJob.perform_async('/status')

      expect(JobHelpers::PoolClient.connection_pool)
        .not_to be(JobHelpers::AltPoolClient.connection_pool)
    end
  end

  describe 'exception path' do
    it 'returns the connection to the pool when a job raises mid-request' do
      20.times do
        expect { JobHelpers::RaisingJob.perform_async }.to raise_error(RuntimeError, 'boom')
      end

      expect(JobHelpers::PoolClient.connection_pool.stats[:checked_out]).to eq(0)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/integration/background_job_spec.rb -e 'credential isolation' -e 'exception path'`
Expected: FAIL — `NameError: uninitialized constant JobHelpers::AltPoolClient` (and `AltPoolJob`, `RaisingJob`).

- [ ] **Step 3: Add the new classes to the support module**

In `spec/support/job_helpers.rb`, inside `module JobHelpers`, add:

```ruby
  class AltPoolClient
    include HttpConnectionPool::Connectable
    self.base_url     = 'https://jobs.example.com'
    self.pool_size    = 5
    self.pool_options = { headers: { 'Authorization' => 'Bearer alt-token' } }
  end

  class AltPoolJob
    include Sidekiq::Job
    def perform(path = '/x')
      AltPoolClient.with_connection { |conn| conn.get(path) }
    end
  end

  class RaisingJob
    include Sidekiq::Job
    def perform
      PoolClient.with_connection { |_conn| raise 'boom' }
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/integration/background_job_spec.rb -e 'credential isolation' -e 'exception path'`
Expected: PASS. The exception-path test proves `with_connection` returns the connection even when the block raises (connection_pool's `with` uses `ensure`), so `checked_out` returns to 0.

- [ ] **Step 5: Run the full new spec file**

Run: `bundle exec rspec spec/integration/background_job_spec.rb`
Expected: all examples PASS.

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop spec/support/job_helpers.rb spec/integration/background_job_spec.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add spec/support/job_helpers.rb spec/integration/background_job_spec.rb
git commit -m "$(cat <<'EOF'
Assert credential isolation and exception-path connection return in jobs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Assert the leak/bloat invariant (object count flat, pool count = distinct origins)

**Files:**
- Modify: `spec/integration/background_job_spec.rb`

**Interfaces:**
- Consumes: `JobHelpers::PoolJob`, `registry`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Write the failing test**

Add to `spec/integration/background_job_spec.rb`:

```ruby
  describe 'memory and bloat invariants' do
    it 'does not accumulate Pool objects as job count grows' do
      GC.start
      base = ObjectSpace.each_object(HttpConnectionPool::Pool).count

      2_000.times { JobHelpers::PoolJob.perform_async('/status') }

      GC.start
      after = ObjectSpace.each_object(HttpConnectionPool::Pool).count

      # One pool for the single origin — not one per job. Allow a small slack
      # for objects GC has not yet collected.
      expect(after - base).to be <= 1
    end

    it 'keeps the registry sized to distinct origins, not job count' do
      2_000.times { JobHelpers::PoolJob.perform_async('/status') }
      expect(registry.stats.length).to eq(1)
    end
  end
```

- [ ] **Step 2: Run the tests**

Run: `bundle exec rspec spec/integration/background_job_spec.rb -e 'memory and bloat'`
Expected: PASS (2 examples). A climbing object count or a registry length > 1 is a real leak/bloat finding — investigate `lib/`, do not loosen the assertion.

- [ ] **Step 3: Run the full new spec file three times to check for flakiness**

Run: `for i in 1 2 3; do bundle exec rspec spec/integration/background_job_spec.rb || break; done`
Expected: all three runs PASS (no order/race flakiness).

- [ ] **Step 4: RuboCop**

Run: `bundle exec rubocop spec/integration/background_job_spec.rb`
Expected: no offenses.

- [ ] **Step 5: Commit**

```bash
git add spec/integration/background_job_spec.rb
git commit -m "$(cat <<'EOF'
Assert no pool-object bloat or registry growth across 2k jobs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add the `bin/job_memory_probe` heavy churn probe

**Files:**
- Create: `bin/job_memory_probe`

**Interfaces:**
- Consumes: `HttpConnectionPool::Connectable`, Sidekiq inline mode.
- Produces: an executable manual probe; not run in CI.

- [ ] **Step 1: Create the probe script**

Create `bin/job_memory_probe`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'http'
require 'sidekiq'
require 'sidekiq/testing'
require 'http_connection_pool'

# Heavy, noisy churn probe — kept OUT of the spec suite (RSS and GC timing are
# not deterministic enough to assert on). Stubs the socket layer so we measure
# OUR retention, not http.rb's buffers, then drives jobs inline and reports
# before/after deltas. Run manually: bin/job_memory_probe [iterations]

module HTTP
  def self.persistent(*) = Object.new
end

Sidekiq::Testing.inline!

ITERATIONS = (ARGV[0] || 20_000).to_i
DIVIDER    = ('-' * 60).freeze

class ProbeClient
  include HttpConnectionPool::Connectable
  self.base_url  = 'https://probe.example.com'
  self.pool_size = 10
end

class ProbeJob
  include Sidekiq::Job
  def perform
    ProbeClient.with_connection { |conn| conn.respond_to?(:get) }
  end
end

def rss_kb
  File.read('/proc/self/status')[/VmRSS:\s+(\d+)/, 1].to_i
rescue StandardError
  -1
end

def pool_count
  ObjectSpace.each_object(HttpConnectionPool::Pool).count
end

GC.start
before = { rss: rss_kb, slots: GC.stat(:heap_live_slots), pools: pool_count,
           registry: HttpConnectionPool::Registry.instance.stats.length }

ITERATIONS.times { ProbeJob.perform_async }

GC.start
after = { rss: rss_kb, slots: GC.stat(:heap_live_slots), pools: pool_count,
          registry: HttpConnectionPool::Registry.instance.stats.length }

puts DIVIDER
puts "job_memory_probe — #{ITERATIONS} inline jobs through ProbeClient"
puts DIVIDER
puts format('  %-22s %12s %12s %12s', 'metric', 'before', 'after', 'delta')
%i[rss slots pools registry].each do |k|
  puts format('  %-22s %12d %12d %12d', k, before[k], after[k], after[k] - before[k])
end
puts DIVIDER
puts 'pools/registry delta ~0 = clean; a climb with iterations = leak/bloat.'
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/job_memory_probe`
Expected: no output.

- [ ] **Step 3: Run it at a small iteration count to confirm it works**

Run: `bin/job_memory_probe 500`
Expected: a table prints; `pools` delta is 0 or 1 and `registry` delta is 0 (one origin reused). RSS/slots may vary.

- [ ] **Step 4: RuboCop**

Run: `bundle exec rubocop bin/job_memory_probe`
Expected: no offenses (auto-fix with `-a` if any; `bin/benchmark` is the style reference).

- [ ] **Step 5: Commit**

```bash
git add bin/job_memory_probe
git commit -m "$(cat <<'EOF'
Add bin/job_memory_probe for heavy out-of-CI job churn measurement

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Update documentation and run full CI

**Files:**
- Modify: `README.md`
- Modify: `.rubocop.yml` (only if `RSpec/DescribeClass` is not already excluded for `spec/integration/**/*`)

**Interfaces:**
- Consumes: everything above.
- Produces: living docs reflecting the new coverage; green CI.

- [ ] **Step 1: Confirm the RuboCop exclusion covers the new spec**

Run: `grep -n 'DescribeClass' -A4 .rubocop.yml`
Expected: an `Exclude` entry already matching `spec/integration/**/*`. If the existing entries list individual files instead of the glob, add `spec/integration/background_job_spec.rb` to the `RSpec/DescribeClass` `Exclude` list (the spec describes cross-cutting behaviour, not one class). If a glob already covers it, make no change.

- [ ] **Step 2: Add the spec to the README integration-spec list**

In `README.md`, find the Rails compatibility / integration-spec description area. After the `zeitwerk_compliance_spec.rb` description, add a sentence noting background-job coverage. Use this wording:

```markdown
The gem is also verified inside background jobs:
`spec/integration/background_job_spec.rb` runs the `Connectable` pool through a
bare `Sidekiq::Job`, an Active Job on the `:test` adapter, and an Active Job on
the `:sidekiq` adapter (all under `Sidekiq::Testing.inline!`, no Redis). It
asserts that jobs hitting one origin share a single pool, that job classes with
different credentials get isolated pools, that a connection is returned to the
pool when a job raises, and that neither the registry nor the live `Pool` count
grows with job count. Sidekiq and Active Job are **test-only** dependencies.
```

- [ ] **Step 3: Note the thread model cross-reference**

In `README.md`, in the existing "Forking app servers" section where Sidekiq is mentioned (the note that Sidekiq runs jobs in threads, not forks), no change is required — confirm it still reads correctly alongside the new coverage. Make no edit unless it now contradicts the new section.

- [ ] **Step 4: Run the full CI suite**

Run: `bundle exec rake ci`
Expected: bundler-audit `No vulnerabilities found`; RuboCop `no offenses`; RSpec all examples pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add README.md .rubocop.yml
git commit -m "$(cat <<'EOF'
Document Sidekiq/Active Job integration coverage in README

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

(If `.rubocop.yml` was not changed in Step 1, add only `README.md`.)

---

## Self-Review

**Spec coverage check (design doc → tasks):**
- Test-only gems `sidekiq`/`activejob` → Task 1.
- `Sidekiq::Testing.inline!`, stubbed sockets, tagged support module → Tasks 1–2.
- Three execution paths (bare Sidekiq::Job, AJ `:test`, AJ `:sidekiq`) → Task 2.
- Pool sharing across jobs → Task 3.
- Pool survives across invocations (reuse, not rebuild) → Task 3.
- Credential isolation across job classes → Task 4.
- Exception path returns connection → Task 4.
- Leak/bloat invariant (object count flat, pool count = distinct origins, 2k in-spec) → Task 5.
- `bin/job_memory_probe` with RSS + GC.stat + registry size, 10k+ churn out of CI → Task 6.
- README + docs update; CI green → Task 7.
All design sections map to a task. No gaps.

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output.

**Type/name consistency:** `JobHelpers::PoolClient`, `PoolJob`, `PoolActiveJob`, `SidekiqAdapterActiveJob`, `AltPoolClient`, `AltPoolJob`, `RaisingJob`, and `perform_active_job`/`registry` helpers are defined in Tasks 1–2 and 4 and referenced consistently thereafter. `pool_size = 5` is used consistently for the `at_most` reuse assertion. Origin string `https://jobs.example.com:443` matches `Registry#extract_origin` output (scheme + host + :443), with a fallback note in Task 2 Step 4.
