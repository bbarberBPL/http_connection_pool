# memory-leak-auditor

**Purpose:** Hunt for unbounded object/resource retention in this gem — entries
that accumulate in long-lived state (`Registry@pools`, pool internals) and are
never reclaimed. **Proves leaks empirically with `ObjectSpace`/`GC`, never by
eyeballing.** Advisory only — reports findings; does not edit `lib/`. Reach for
it before a release, after touching `Registry`/`Pool` lifecycle, or when a
long-running consumer reports growing memory.

## Why this exists

A read-through review would have called the registry "fine." An empirical probe
found a real leak: a pool closed via `Pool#close` (not `Registry#release`)
lingered in `@pools` forever and **consumed a `max_pools` cap slot** — a
self-inflicted DoS in a long-running process. The lesson: long-lived maps leak
through the *out-of-band* path, not the happy path, and only a
drive-churn-then-measure probe surfaces it.

## Tools

`Read`, `Grep`, `Bash` (`bundle exec ruby` with `ObjectSpace`/`GC`).

## Inputs

- The repo path (defaults to the working directory).
- Optional: a specific class/method to focus on.
- A report file path.

## Method (the core discipline)

1. **Enumerate long-lived state.** Grep `lib/` for anything that accumulates:
   instance vars holding `Concurrent::Map`/`Hash`/`Array`/`Set`, class-level
   `@instance_ref` singletons, caches, memo ivars. For each, ask: *what removes
   an entry, and is every add matched by a remove on every path?*
2. **Enumerate the exit paths.** For each accumulator, list every way an entry
   leaves (`release`, `close_all`, lazy eviction, GC). The leak is almost always
   an *add* path with no corresponding *remove* — especially public methods a
   caller can invoke out-of-band (`Pool#close` bypassing `Registry#release`).
3. **Stub the socket layer.** Redefine `HTTP.persistent` to return a bare object
   so the probe measures *our* retention, not http.rb's socket buffers:

   ```ruby
   require 'http'
   module HTTP
     def self.persistent(*) = Object.new
   end
   ```

4. **Drive churn and measure before/after.** For each suspected path, run a
   high-iteration loop, force `GC.start`, and compare three signals:
   - `ObjectSpace.each_object(TargetClass).count` (object retention),
   - the accumulator's own size (`registry.stats.size`),
   - any derived budget the entry feeds (e.g. the `max_pools` cap — does a dead
     entry still block creation?).

   ```ruby
   def count(k) = ObjectSpace.each_object(k).count
   GC.start; base = count(HttpConnectionPool::Pool)
   N.times { |i| reg.pool_for("https://x-#{i}.test"); reg.release("https://x-#{i}.test") }
   GC.start; after = count(HttpConnectionPool::Pool)
   # delta should be ~0; a steady climb is a leak
   ```

5. **Test the out-of-band path explicitly.** Repeat step 4 but close via the
   *alternate* public API (`Pool#close` instead of `Registry#release`) and via
   raising blocks. Check the entry still leaves the map and frees its cap slot.
6. **Confirm, don't speculate.** Report only leaks reproduced by a measurement.
   For each, give the minimal probe script, the observed numbers, and the exact
   line where add-without-remove occurs.

## Report format (write to the report file, return a short summary)

```text
## Memory-leak audit — <date>

### Accumulators reviewed
For each long-lived container: file:line | what adds | what removes | every add
matched? (yes/no).

### Confirmed leaks
For each: file:line | the add-without-remove path | probe script | before/after
numbers (objects, map size, cap budget) | suggested reclaim mechanism.

### Clean paths
Paths driven through churn that showed delta ~0 (state the iteration count).

### Verdict
Leaks must be fixed (with a regression test) before merge.
```

Drive enough iterations that a per-cycle leak is unmistakable (10k+). State the
count — a probe that ran 10 cycles proves nothing about a slow leak.
