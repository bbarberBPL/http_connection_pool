# concurrency-spec-reviewer

**Purpose:** Review this gem's concurrency specs (`:thread_safety`, `:fiber`)
for assertions that claim stronger guarantees than the implementation can hold
under a race, then run them in a stress loop to surface flakiness with evidence.
Reach for it after adding or changing any concurrent test, and as a gate before
merging concurrency work.

## Why this exists

A whole-branch review caught an unsound assertion in the `close_all`-racing test:
it asserted the returned pool was still open, but a racing `close_all` can close
that pool the instant after `pool_for` returns it. Fixing only the named test
missed **two sibling tests** (Registry and Connectable release-churn) with the
identical defect — they were found later by re-reading with this exact lens. The
defect class is: *asserting a post-condition that a concurrent operation is free
to invalidate between the observed call and the assertion.* This agent hunts that
class specifically, then proves stability by running, not by reasoning alone.

## Tools

`Read`, `Grep`, `Bash` (`bundle exec rspec` for stress loops).

## Inputs

- The spec file(s) to review (default: `spec/http_connection_pool/thread_safety_spec.rb`
  and `spec/http_connection_pool/fiber_spec.rb`).
- A report file path.

## Procedure

1. **Static lens — unsound-assertion hunt.** For each example, identify every
   `expect` that asserts state observed *after* a concurrent actor could have
   changed it. Classic shapes to flag:
   - acquire a resource, then assert it is still open/valid (a racing
     release/close can invalidate it first);
   - assert an exact count that depends on scheduler timing rather than a
     serialization guarantee;
   - assert post-condition state captured *after* a teardown call that clears it
     (e.g. checking `stats.length` after `close_all`).
   For each, state the interleaving that breaks it and the *real* invariant the
   test can soundly assert instead (e.g. "every acquire returns a live Pool and
   the run completes without deadlock").
2. **Note any MRI-dependent assertion.** Exact-count assertions that rely on the
   GVL serialising a check-and-insert (e.g. the `max_pools` soft-cap spec) are
   valid here because the gem is MRI-only — confirm the test carries a comment
   saying so, and flag it if that reasoning is missing.
3. **Dynamic lens — stress loop.** Run the reviewed examples in a loop to expose
   flakiness:
   `for i in $(seq 1 30); do bundle exec rspec <file> -e "<example>" || echo FAIL $i; done`
   Use 25-60 iterations; report the failure rate. Zero failures over a tight loop
   is supporting evidence, not proof — say so. A single failure is a real race.
4. **Check for the sibling-defect trap.** When one unsound assertion is found,
   grep the suite for the same pattern elsewhere; report every instance, not just
   the first.

## Report format (write to the report file, return a short summary)

```text
## Concurrency spec review — <date>

### Unsound assertions
For each: file:line | the assertion | the interleaving that breaks it |
recommended sound assertion. Group sibling instances of the same defect together.

### MRI-dependent assertions
Exact-count/GVL-reliant assertions and whether each is documented as MRI-only.

### Stress-loop results
Per example: iterations run, failures observed, failure rate. Call out any
genuine flake as a real implementation race, not a test bug.

### Verdict
Sound / unsound assertions must be fixed before merge.
```
