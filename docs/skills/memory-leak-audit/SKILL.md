---
name: memory-leak-audit
description: Use when checking this gem for memory or resource leaks — before a release, after changing Registry/Pool lifecycle code, or when a long-running consumer reports growing memory. Proves retention empirically with ObjectSpace/GC rather than by reading the code.
---

# Memory-leak audit

A repeatable probe for unbounded retention in `http_connection_pool`. The rule
that makes it trustworthy: **a read-through never proves the absence of a leak —
drive churn and measure.** (An empirical probe is what caught a closed pool
lingering in the registry and eating a `max_pools` cap slot; a code review had
called the same method fine.)

For a broad multi-accumulator sweep, dispatch the
[`memory-leak-auditor`](../../agents/memory-leak-auditor.md) agent. Use these
steps for a quick inline check of a specific method.

## Steps

1. **Find the accumulator.** Identify the long-lived container the method feeds
   (`Registry@pools`, a cache ivar, a class-level singleton). Ask: what removes
   an entry, and is every add matched by a remove on *every* path — including
   out-of-band ones like `Pool#close` bypassing `Registry#release`?

2. **Write a probe that stubs the socket layer** so you measure our retention,
   not http.rb's buffers:

   ```ruby
   $LOAD_PATH.unshift File.expand_path('lib', Dir.pwd)
   require 'http_connection_pool'
   require 'http'
   module HTTP
     def self.persistent(*) = Object.new
   end
   def count(k) = ObjectSpace.each_object(k).count
   ```

3. **Drive churn, force GC, compare before/after** on three signals — object
   count, accumulator size, and any budget the entry feeds (e.g. the cap):

   ```ruby
   reg = HttpConnectionPool::Registry.new
   GC.start; base = count(HttpConnectionPool::Pool)
   20_000.times do |i|
     reg.pool_for("https://x-#{i}.test")
     reg.release("https://x-#{i}.test")
   end
   GC.start
   puts "delta=#{count(HttpConnectionPool::Pool) - base} map=#{reg.stats.size}"
   # delta ~0 and map ~0 = clean; a steady climb = leak
   ```

4. **Repeat for the out-of-band path** — close via `Pool#close` instead of
   `Registry#release`, and via a raising block — and confirm the entry still
   leaves the map and frees its cap slot. This is where leaks hide.

5. **If you find a leak, fix it test-first.** Write a failing spec (cap not
   consumed by a dead entry; a sweep reclaims it), then the minimal fix. See
   `Registry#sweep_closed!` and the `live_pool_count` cap check for the existing
   reclaim mechanism, and the `:thread_safety`/registry specs for the pattern.

6. **Run `bundle exec rake ci`** — it must stay green (RuboCop + RSpec +
   bundler-audit).

State the iteration count in any finding: a 10-cycle probe proves nothing about
a slow leak. Use 10k+.
