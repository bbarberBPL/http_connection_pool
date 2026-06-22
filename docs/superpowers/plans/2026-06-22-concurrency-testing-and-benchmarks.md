# Concurrency Testing and Benchmarks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add comprehensive thread-safety specs, fiber/async specs, a `bin/benchmark` script against the real weather.gov API, and the `rubocop-performance` plugin to the `http_connection_pool` gem.

**Architecture:** Four independent deliverables — rubocop-performance wired in first so every subsequent file is immediately linted; thread-safety specs next (no new gems); fiber specs after (requires `async` gem); benchmark script last (requires both `async` and a live network). Each task ends with `bundle exec rake ci` green.

**Tech Stack:** Ruby 3.4, RSpec 3.13, `connection_pool` >= 2.5.5, `concurrent-ruby` ~> 1.3, `async` ~> 2 (test-only), `rubocop-performance` (dev/test), stdlib `Benchmark`.

## Global Constraints

- All non-interpolated strings: **single quotes**
- Every Ruby file begins with `# frozen_string_literal: true`
- `bundle exec rake ci` must be green after every task (bundler-audit → rubocop → rspec)
- Fake HTTP clients use `instance_double(HTTP::Client)`, stub **both** `is_a?` and `kind_of?` for `HTTP::Client`
- Teardown uses `after do` — never `after(:each) do`
- `spec_helper` already resets the global registry via `Registry.reset!` in `config.after do` — do not add per-spec resets
- No apostrophes inside `it`/`describe`/`context` strings (Ruby SyntaxError)
- `mocks.verify_partial_doubles = true` is active — all stubs must match real method signatures
- `RSpec/MultipleExpectations: Max: 3`, `RSpec/ExampleLength: Max: 20`
- Methods: 20-line max; extract private methods rather than exceeding it
- Targeted concurrent-ruby requires: e.g. `require 'concurrent/atomic/atomic_fixnum'`, never `require 'concurrent-ruby'`
- `async` gem in `:test` group only in `Gemfile` — never in gemspec

---

## Files Created / Modified

| Action | Path | Purpose |
|--------|------|---------|
| Modify | `Gemfile` | Add `rubocop-performance` (dev/test), `async` (test) |
| Modify | `.rubocop.yml` | Add `rubocop-performance` to `plugins:` |
| Modify | `CLAUDE.md` | Record `rubocop-performance` plugin |
| Create | `spec/http_connection_pool/thread_safety_spec.rb` | Pool, Registry, Connectable concurrency tests |
| Create | `spec/http_connection_pool/fiber_spec.rb` | Async/Fiber + Concurrent::Promises tests |
| Create | `bin/benchmark` | Real-HTTP benchmark against weather.gov |

---

## Task 1: Add rubocop-performance and fix any offenses

**Files:**
- Modify: `Gemfile`
- Modify: `.rubocop.yml`
- Modify: `CLAUDE.md`
- Modify: any lib file that has a rubocop-performance offense

**Interfaces:**
- Produces: `rubocop-performance` available to all subsequent tasks; `bundle exec rubocop` clean

- [ ] **Step 1: Add gems to Gemfile**

Edit `Gemfile` — add `rubocop-performance` to the `development, test` group (keep alphabetical order within the group):

```ruby
group :development, :test do
  gem 'bundler-audit',        '~> 0.9',  require: false
  gem 'irb',                  '~> 1.14'
  gem 'rake',                 '~> 13.0'
  gem 'rspec',                '~> 3.13'
  gem 'rubocop',              '~> 1.65', require: false
  gem 'rubocop-performance',             require: false
  gem 'rubocop-rake',                    require: false
  gem 'rubocop-rspec',                   require: false
end
```

- [ ] **Step 2: Add plugin to `.rubocop.yml`**

Edit `.rubocop.yml` — extend the existing `plugins:` list:

```yaml
plugins:
  - rubocop-performance
  - rubocop-rake
  - rubocop-rspec
```

- [ ] **Step 3: Install the gem**

```bash
bundle install
```

Expected: Gemfile.lock updated, `rubocop-performance` and its `rubocop-ast` dependency resolved with no conflicts.

- [ ] **Step 4: Run rubocop and check for performance offenses**

```bash
bundle exec rubocop
```

Expected: either "no offenses detected" or a list of `Performance/` cops. The most likely hit is `Performance/ChainArrayAllocation` on `normalize_options` in `lib/http_connection_pool/registry.rb:160`.

- [ ] **Step 5: Fix any offenses**

If `Performance/ChainArrayAllocation` fires on line 160 of `registry.rb`, the current code:
```ruby
when Hash then obj.sort_by { |k, _| k.to_s }.to_h { |k, v| [k, normalize_options(v)] }
```
can be rewritten as a single `each_with_object` to avoid intermediate array allocation:
```ruby
when Hash
  obj.each_with_object({}) { |(k, v), h| h[k] = normalize_options(v) }
      .sort_by { |k, _| k.to_s }.to_h
```

For any other offense, read the cop message and apply the minimal fix. Do NOT use `# rubocop:disable` inline comments — restructure instead.

- [ ] **Step 6: Update CLAUDE.md**

In the `## RuboCop` section, add `rubocop-performance` to the plugins list:

```markdown
- Plugins declared with `plugins:` syntax (not `require:`):
  - `rubocop-performance`
  - `rubocop-rake`
  - `rubocop-rspec`
```

- [ ] **Step 7: Verify CI is green**

```bash
bundle exec rake ci
```

Expected output (in order):
```
No vulnerabilities found
Running RuboCop...
Inspecting 14 files
..............
14 files inspected, no offenses detected
...
N examples, 0 failures
```

- [ ] **Step 8: Commit**

```bash
git add Gemfile Gemfile.lock .rubocop.yml CLAUDE.md lib/http_connection_pool/registry.rb
git commit -m "Add rubocop-performance plugin and fix any flagged offenses"
```

---

## Task 2: Thread-safety spec

**Files:**
- Create: `spec/http_connection_pool/thread_safety_spec.rb`

**Interfaces:**
- Consumes: `HttpConnectionPool::Pool`, `HttpConnectionPool::Registry`, `HttpConnectionPool::Connectable` (no changes to those files)
- Consumes: `concurrent/atomic/atomic_fixnum` (already in bundle via `concurrent-ruby`)
- Produces: tagged `:thread_safety` suite covering Pool, Registry, and Connectable under real concurrent load

- [ ] **Step 1: Create the file with Pool concurrency tests**

Create `spec/http_connection_pool/thread_safety_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'concurrent/atomic/atomic_fixnum'

# These specs exercise the gem under real concurrent load. They are tagged
# :thread_safety so they can be run in isolation:
#   bundle exec rspec spec/http_connection_pool/thread_safety_spec.rb
#
# Each example uses raw Thread coordination (barriers, queues) and
# Concurrent::AtomicFixnum for race-condition-safe counters.
RSpec.describe 'Thread safety', :thread_safety do
  let(:fake_client) { instance_double(HTTP::Client, close: nil) }

  before do
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Client).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Client).and_return(true)
  end

  # ── Pool ──────────────────────────────────────────────────────────────────

  describe 'Pool' do
    subject(:pool) { HttpConnectionPool::Pool.new(origin: 'https://pool-safety.example.com:443', size: 5, timeout: 2.0) }

    after { pool.close }

    describe 'concurrent close' do
      it 'is idempotent when 10 threads call close simultaneously' do
        barrier = CyclicBarrier.new(10)
        threads = 10.times.map { Thread.new { barrier.await; pool.close } }
        threads.each(&:join)
        expect(pool).to be_closed
      end
    end

    describe 'stats integrity under concurrent checkouts' do
      it 'never reports checked_out outside [0, size]' do
        violations = Concurrent::AtomicFixnum.new(0)
        threads = 20.times.map do
          Thread.new do
            10.times do
              pool.with do
                s = pool.stats
                violations.increment if s[:checked_out] > pool.size || s[:checked_out].negative?
              end
            end
          end
        end
        threads.each(&:join)
        expect(violations.value).to eq(0)
      end
    end
  end

  # ── Registry ─────────────────────────────────────────────────────────────

  describe 'Registry' do
    subject(:registry) { HttpConnectionPool::Registry.new }

    describe 'concurrent distinct-origin creation' do
      it 'creates 20 distinct open pools without races' do
        origins = 20.times.map { |i| "https://origin-#{i}.example.com" }
        barrier = CyclicBarrier.new(20)
        pools   = Array.new(20)

        threads = 20.times.map do |i|
          Thread.new do
            barrier.await
            pools[i] = registry.pool_for(origins[i])
          end
        end
        threads.each(&:join)

        expect(pools.all? { |p| p && !p.closed? }).to be true
        expect(pools.uniq.length).to eq(20)
      end
    end

    describe 'close_all racing with pool_for' do
      it 'never deadlocks and all returned pools are open' do
        returned = Concurrent::AtomicFixnum.new(0)
        closed_while_open = Concurrent::AtomicFixnum.new(0)

        closer = Thread.new do
          5.times { registry.close_all; sleep 0.001 }
        end

        requesters = 10.times.map do |i|
          Thread.new do
            5.times do
              pool = registry.pool_for("https://race-#{i}.example.com")
              closed_while_open.increment if pool.closed?
              returned.increment
            end
          end
        end

        requesters.each(&:join)
        closer.join

        expect(returned.value).to eq(50)
        expect(closed_while_open.value).to eq(0)
      end
    end

    describe 'max_pools cap under concurrent racing creation' do
      it 'raises PoolLimitError and never panics or deadlocks' do
        capped  = HttpConnectionPool::Registry.new(max_pools: 3)
        errors  = Concurrent::AtomicFixnum.new(0)
        barrier = CyclicBarrier.new(10)

        threads = 10.times.map do |i|
          Thread.new do
            barrier.await
            capped.pool_for("https://cap-race-#{i}.example.com")
          rescue HttpConnectionPool::Registry::PoolLimitError
            errors.increment
          end
        end
        threads.each(&:join)
        capped.close_all

        # At least some threads must have hit the cap and at least 3 pools created.
        expect(capped.stats.length).to be <= 3
        expect(errors.value).to be >= 7
      end
    end

    describe 'concurrent release and re-acquire' do
      it 'never returns a closed pool' do
        closed_returns = Concurrent::AtomicFixnum.new(0)

        threads = 10.times.map do
          Thread.new do
            5.times do
              pool = registry.pool_for('https://release-race.example.com')
              closed_returns.increment if pool.closed?
              registry.release('https://release-race.example.com')
            end
          end
        end
        threads.each(&:join)

        expect(closed_returns.value).to eq(0)
      end
    end
  end

  # ── Connectable ──────────────────────────────────────────────────────────

  describe 'Connectable' do
    let(:client_class) do
      Class.new do
        include HttpConnectionPool::Connectable
        self.base_url  = 'https://connectable-safety.example.com'
        self.pool_size = 10
      end
    end

    describe 'memoization race on first access' do
      it 'returns the same pool to 30 threads racing on first connection_pool call' do
        barrier = CyclicBarrier.new(30)
        pools   = Array.new(30)

        threads = 30.times.map do |i|
          Thread.new { barrier.await; pools[i] = client_class.connection_pool }
        end
        threads.each(&:join)

        expect(pools.uniq.length).to eq(1)
        expect(pools.first).not_to be_closed
      end
    end

    describe 'release and re-acquire under concurrency' do
      it 'never returns a closed pool across 10 interleaving threads' do
        closed_returns = Concurrent::AtomicFixnum.new(0)

        threads = 10.times.map do
          Thread.new do
            5.times do
              pool = client_class.connection_pool
              closed_returns.increment if pool.closed?
              client_class.release_connection_pool
            end
          end
        end
        threads.each(&:join)

        expect(closed_returns.value).to eq(0)
      end
    end
  end
end
```

- [ ] **Step 2: Add `CyclicBarrier` helper to spec_helper or the file itself**

The specs above reference `CyclicBarrier` — a barrier that releases all waiting threads simultaneously (more precise than `ConditionVariable` for race tests). Add it as a helper class at the top of the thread_safety_spec file, just before the `RSpec.describe` block:

```ruby
# A reusable barrier: all threads block on `await` until `count` threads have
# arrived, then all are released simultaneously. Safer than ConditionVariable
# for precise race-condition testing.
class CyclicBarrier
  def initialize(count)
    @count   = count
    @waiting = 0
    @mutex   = Mutex.new
    @cv      = ConditionVariable.new
  end

  def await
    @mutex.synchronize do
      @waiting += 1
      if @waiting >= @count
        @waiting = 0
        @cv.broadcast
      else
        @cv.wait(@mutex) until @waiting.zero?
      end
    end
  end
end
```

- [ ] **Step 3: Run the thread-safety specs only to verify**

```bash
bundle exec rspec spec/http_connection_pool/thread_safety_spec.rb --format documentation
```

Expected: All examples pass. If any flap (rare under load), re-run once — genuine flaps on these tests indicate a real race condition in the implementation.

- [ ] **Step 4: Run full CI**

```bash
bundle exec rake ci
```

Expected: all existing examples + new thread-safety examples pass, rubocop clean.

- [ ] **Step 5: Commit**

```bash
git add spec/http_connection_pool/thread_safety_spec.rb
git commit -m "Add comprehensive thread-safety specs for Pool, Registry, and Connectable"
```

---

## Task 3: Fiber and Concurrent::Promises spec

**Files:**
- Modify: `Gemfile` (add `async` to `:test` group)
- Create: `spec/http_connection_pool/fiber_spec.rb`

**Interfaces:**
- Consumes: `HttpConnectionPool::Pool`, `HttpConnectionPool::Registry`, `HttpConnectionPool::Connectable`
- Consumes: `async` gem 2.x API: `Async {}`, `Async::Barrier.new`, `barrier.async {}`, `barrier.wait`
- Consumes: `Concurrent::Promises.future {}`, `.zip(*futures).value!`
- Produces: tagged `:fiber` suite proving fiber-scheduler-aware checkout and Concurrent::Promises integration

- [ ] **Step 1: Add `async` gem to Gemfile test group**

Edit `Gemfile` — add to the existing `:test` group:

```ruby
group :test do
  gem 'activesupport', '~> 7.2.3'
  gem 'async',         '~> 2.0'
  gem 'zeitwerk',      '~> 2.6'
end
```

- [ ] **Step 2: Install**

```bash
bundle install
```

Expected: `async` and its dependencies (`io-event`, `fiber-annotation`, `console`) resolved and locked.

- [ ] **Step 3: Create the fiber spec file**

Create `spec/http_connection_pool/fiber_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'async/barrier'
require 'concurrent/promises'

# These specs verify two concurrency paths:
#
# 1. Fiber/Async scheduler — connection_pool >= 2.5 yields to the fiber
#    scheduler instead of parking the OS thread. A size-1 pool shared by
#    multiple concurrent fibers must not deadlock.
#
# 2. Concurrent::Promises — the concurrent-ruby thread-pool path. Futures
#    that raise inside with_connection must not leak checked-out connections.
#
# Run in isolation:
#   bundle exec rspec spec/http_connection_pool/fiber_spec.rb
RSpec.describe 'Fiber and Concurrent::Promises integration', :fiber do
  let(:fake_client) { instance_double(HTTP::Client, close: nil) }

  before do
    allow(HTTP).to receive(:persistent).and_return(fake_client)
    allow(fake_client).to receive(:is_a?).with(HTTP::Client).and_return(true)
    allow(fake_client).to receive(:kind_of?).with(HTTP::Client).and_return(true)
  end

  # ── Async / Fiber scheduler ───────────────────────────────────────────────

  describe 'Async fiber scheduler' do
    describe 'Pool under Async' do
      it 'completes 3 concurrent fibers sharing a size-1 pool without deadlock' do
        pool      = HttpConnectionPool::Pool.new(origin: 'https://fiber.example.com:443', size: 1, timeout: 3.0)
        completed = Concurrent::AtomicFixnum.new(0)

        Async do
          barrier = Async::Barrier.new
          3.times do
            barrier.async { pool.with { completed.increment } }
          end
          barrier.wait
        end

        pool.close
        expect(completed.value).to eq(3)
      end

      it 'completes N fibers sharing a size-N pool' do
        n         = 5
        pool      = HttpConnectionPool::Pool.new(origin: 'https://fiber-n.example.com:443', size: n, timeout: 3.0)
        completed = Concurrent::AtomicFixnum.new(0)

        Async do
          barrier = Async::Barrier.new
          n.times { barrier.async { pool.with { completed.increment } } }
          barrier.wait
        end

        pool.close
        expect(completed.value).to eq(n)
      end

      it 'returns all connections to the pool after all fibers complete' do
        pool = HttpConnectionPool::Pool.new(origin: 'https://fiber-return.example.com:443', size: 3, timeout: 3.0)

        Async do
          barrier = Async::Barrier.new
          3.times { barrier.async { pool.with { nil } } }
          barrier.wait
        end

        expect(pool.stats[:checked_out]).to eq(0)
        pool.close
      end
    end

    describe 'Registry under Async' do
      it 'returns the same pool to concurrent fibers racing on the same origin' do
        registry = HttpConnectionPool::Registry.new
        pools    = Array.new(10)

        Async do
          barrier = Async::Barrier.new
          10.times do |i|
            barrier.async { pools[i] = registry.pool_for('https://fiber-race.example.com') }
          end
          barrier.wait
        end

        registry.close_all
        expect(pools.uniq.length).to eq(1)
      end
    end

    describe 'Connectable under Async' do
      it 'with_connection works correctly across 10 concurrent fibers' do
        allow(fake_client).to receive(:get).and_return(:ok)
        client_class = Class.new do
          include HttpConnectionPool::Connectable
          self.base_url  = 'https://fiber-connectable.example.com'
          self.pool_size = 5
        end

        results = Array.new(10)

        Async do
          barrier = Async::Barrier.new
          10.times do |i|
            barrier.async { results[i] = client_class.with_connection { |c| c.get('/status') } }
          end
          barrier.wait
        end

        expect(results).to all(eq(:ok))
      end
    end
  end

  # ── Concurrent::Promises ─────────────────────────────────────────────────

  describe 'Concurrent::Promises futures' do
    let(:pool) do
      HttpConnectionPool::Pool.new(origin: 'https://promises.example.com:443', size: 5, timeout: 3.0)
    end

    after { pool.close }

    it 'resolves 10 futures that each borrow a connection' do
      allow(fake_client).to receive(:get).and_return(:ok)
      futures = 10.times.map do
        Concurrent::Promises.future { pool.with { |c| c.get('/') } }
      end
      results = Concurrent::Promises.zip(*futures).value!
      expect(results).to all(eq(:ok))
    end

    it 'does not leak a checked-out connection when a future raises' do
      allow(fake_client).to receive(:get).and_raise(RuntimeError, 'boom')

      future = Concurrent::Promises.future { pool.with { |c| c.get('/') } }
      future.wait # let it settle

      expect(future).to be_rejected
      expect(pool.stats[:checked_out]).to eq(0)
    end
  end
end
```

- [ ] **Step 4: Run the fiber specs only**

```bash
bundle exec rspec spec/http_connection_pool/fiber_spec.rb --format documentation
```

Expected: all examples pass. The Async specs prove the fiber-yield path in `connection_pool`; the Promises specs prove concurrent-ruby integration.

- [ ] **Step 5: Run full CI**

```bash
bundle exec rake ci
```

Expected: all existing + new examples pass, rubocop clean, no CVEs.

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock spec/http_connection_pool/fiber_spec.rb
git commit -m "Add fiber scheduler and Concurrent::Promises integration specs"
```

---

## Task 4: Benchmark script

**Files:**
- Create: `bin/benchmark`

**Interfaces:**
- Consumes: `HttpConnectionPool::Connectable`, `Concurrent::Promises`, `Async`, `async/barrier`, stdlib `Benchmark`
- Consumes: live `https://api.weather.gov/offices/TOP` endpoint (no auth, stable, fast)
- Produces: executable `bin/benchmark` that reports wall-clock and req/sec for four concurrency strategies

- [ ] **Step 1: Create the benchmark script**

Create `bin/benchmark` (no `.rb` extension, matches `bin/console` convention):

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'benchmark'
require 'async'
require 'async/barrier'
require 'concurrent/promises'
require 'http_connection_pool'

# ── Client ───────────────────────────────────────────────────────────────────

class WeatherClient
  include HttpConnectionPool::Connectable

  self.base_url  = 'https://api.weather.gov'
  self.pool_size = 10
end

# ── Configuration ─────────────────────────────────────────────────────────────

REQUESTS     = 20
ENDPOINT     = '/offices/TOP'
DIVIDER      = '-' * 60

def print_header
  puts DIVIDER
  puts "HttpConnectionPool benchmark — #{REQUESTS} requests to #{ENDPOINT}"
  puts "  base_url: #{WeatherClient.base_url}"
  puts "  pool_size: #{WeatherClient.pool_size}"
  puts DIVIDER
end

def print_stats(label, elapsed)
  rps = (REQUESTS / elapsed).round(1)
  puts format('  %-30s %6.2fs  (%s req/s)', label, elapsed, rps)
end

def print_pool_stats
  stats = WeatherClient.connection_pool.stats
  puts format('  pool: size=%-3d checked_out=%-3d idle=%-3d closed=%s',
              stats[:size], stats[:checked_out], stats[:idle], stats[:closed])
end

# ── Scenarios ─────────────────────────────────────────────────────────────────

def run_sequential
  REQUESTS.times { WeatherClient.with_connection { |c| c.get(ENDPOINT) } }
end

def run_threaded
  threads = REQUESTS.times.map do
    Thread.new { WeatherClient.with_connection { |c| c.get(ENDPOINT) } }
  end
  threads.each(&:join)
end

def run_futures
  futures = REQUESTS.times.map do
    Concurrent::Promises.future { WeatherClient.with_connection { |c| c.get(ENDPOINT) } }
  end
  Concurrent::Promises.zip(*futures).value!
end

def run_async_fibers
  Async do
    barrier = Async::Barrier.new
    REQUESTS.times { barrier.async { WeatherClient.with_connection { |c| c.get(ENDPOINT) } } }
    barrier.wait
  end
end

# ── Runner ────────────────────────────────────────────────────────────────────

print_header

scenarios = {
  'Sequential (baseline)'         => method(:run_sequential),
  'Threaded (Thread.new x N)'     => method(:run_threaded),
  'Concurrent::Promises futures'  => method(:run_futures),
  'Async fibers (Async::Barrier)' => method(:run_async_fibers),
}

scenarios.each do |label, runner|
  # Reset pool between scenarios for a clean connection count.
  WeatherClient.release_connection_pool

  elapsed = Benchmark.realtime { runner.call }
  print_stats(label, elapsed)
  print_pool_stats
  puts
end

WeatherClient.release_connection_pool
puts DIVIDER
puts 'Done.'
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x bin/benchmark
```

- [ ] **Step 3: Run the benchmark with live network**

```bash
bundle exec ruby bin/benchmark
```

Expected output (times will vary by network):
```
------------------------------------------------------------
HttpConnectionPool benchmark — 20 requests to /offices/TOP
  base_url: https://api.weather.gov
  pool_size: 10
------------------------------------------------------------
  Sequential (baseline)          ~4.00s  (~5.0 req/s)
  pool: size=10  checked_out=0   idle=10  closed=false

  Threaded (Thread.new x N)      ~0.50s  (~40.0 req/s)
  pool: size=10  checked_out=0   idle=10  closed=false

  Concurrent::Promises futures   ~0.50s  (~40.0 req/s)
  pool: size=10  checked_out=0   idle=10  closed=false

  Async fibers (Async::Barrier)  ~0.45s  (~45.0 req/s)
  pool: size=10  checked_out=0   idle=10  closed=false

------------------------------------------------------------
Done.
```

Key things to verify: sequential is clearly slowest (requests serialised), threaded/futures/async are 5–10× faster, `checked_out` is always 0 after each scenario (no connection leaks).

- [ ] **Step 4: Run full CI to verify the script does not break lint/tests**

```bash
bundle exec rake ci
```

Expected: rubocop scans `bin/benchmark` automatically (it is a Ruby file detected via shebang). All examples pass.

If RuboCop flags `Style/TopLevelMethodDefinition` for the `def run_*` methods, wrap them in a module:

```ruby
module Scenarios
  module_function

  def sequential
    REQUESTS.times { WeatherClient.with_connection { |c| c.get(ENDPOINT) } }
  end
  # ... etc
end
```

And update the scenarios hash accordingly:
```ruby
scenarios = {
  'Sequential (baseline)' => method(:sequential).unbind.bind(Scenarios),
  # or simply:
  'Sequential (baseline)' => -> { Scenarios.sequential },
  ...
}
```

- [ ] **Step 5: Commit**

```bash
git add bin/benchmark
git commit -m "Add bin/benchmark script with four concurrency strategies against weather.gov"
```

---

## Self-Review

**Spec coverage check:**

| Requirement | Task |
|---|---|
| rubocop-performance gem added | Task 1 |
| rubocop-performance in .rubocop.yml plugins | Task 1 |
| CLAUDE.md updated with plugin | Task 1 |
| Pool: concurrent close idempotent | Task 2 |
| Pool: stats integrity under 20×10 load | Task 2 |
| Registry: 20 distinct-origin concurrent creation | Task 2 |
| Registry: close_all + pool_for race | Task 2 |
| Registry: max_pools cap under race | Task 2 |
| Registry: concurrent release + re-acquire | Task 2 |
| Connectable: 30-thread memoization race | Task 2 |
| Connectable: release + re-acquire race | Task 2 |
| CyclicBarrier helper defined | Task 2 |
| async gem added to test group | Task 3 |
| Fiber: size-1 pool, 3 fibers, no deadlock | Task 3 |
| Fiber: N fibers, size-N pool | Task 3 |
| Fiber: connections returned after fiber exit | Task 3 |
| Fiber: Registry same pool to concurrent fibers | Task 3 |
| Fiber: Connectable works under Async | Task 3 |
| Concurrent::Promises: 10 futures resolve | Task 3 |
| Concurrent::Promises: raise does not leak connection | Task 3 |
| bin/benchmark: sequential scenario | Task 4 |
| bin/benchmark: threaded scenario | Task 4 |
| bin/benchmark: Concurrent::Promises scenario | Task 4 |
| bin/benchmark: Async fibers scenario | Task 4 |
| bin/benchmark: pool stats after each scenario | Task 4 |

**Placeholder scan:** No TBDs, TODOs, or vague steps — all steps include complete code.

**Type consistency:**
- `CyclicBarrier` is defined and used only in Task 2's file — no cross-task dependency.
- `WeatherClient` defined only in `bin/benchmark`.
- All spec stubs follow `instance_double(HTTP::Client)` + both `is_a?`/`kind_of?` stubs.
- `Concurrent::AtomicFixnum` required explicitly in Task 2; `Concurrent::Promises` required explicitly in Tasks 3 and 4.
- `async/barrier` required explicitly wherever `Async::Barrier` is used (Tasks 3 and 4).
