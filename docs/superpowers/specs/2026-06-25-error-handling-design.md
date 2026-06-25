# Error handling and safe pool keying — design

## Goal

Give `http_connection_pool` a single, unified error hierarchy rooted at
`HttpConnectionPool::Error`, so a caller can `rescue HttpConnectionPool::Error`
to catch any failure originating in the pool/registry layer. While adding the
hierarchy, close a real defect found during review: the registry's pool-key
derivation uses `Object#inspect`, which silently fragments (identical config →
different keys) and can silently collide (different credentials → same key) for
option values whose `inspect` omits distinguishing state — most importantly
`ssl_context:`. The fix raises a new `OptionKeyError` rather than guessing.

This is an MRI-tested, test-only-dependency gem (see CLAUDE.md). No new runtime
dependency is added. The work is pre-release (0.1.0 not yet on RubyGems), so we
may re-parent existing error constants now while preserving their names as
aliases for safety.

## Background — the keying defect (empirically confirmed)

`Registry#pool_key` is:

```ruby
Digest::SHA256.hexdigest("#{origin}|#{normalize_options(options).inspect}")
```

`normalize_options` deep-sorts hash keys (good — insertion order no longer
matters), but the final `.inspect` is a human-readable format, not a canonical,
injective serializer. Probing confirmed:

- **No collision via scalars/strings/hashes** — `inspect` escapes embedded
  quotes, so a crafted header value cannot impersonate two headers. Plain
  options are safe.
- **`ssl_context:` fragments** — two `OpenSSL::SSL::SSLContext` objects with
  identical configuration produce different keys, because `SSLContext#inspect`
  includes the object's memory address. Same TLS config → multiple pools.
- **`ssl_context:` can collide (the security bug)** — `SSLContext#inspect`
  exposes only `@verify_mode` and `@verify_hostname`. Two contexts with
  different client certificates / private keys / `ca_file` but the same
  verify_mode produce the **same** key — different credentials, shared pool,
  mixed connections. The general flaw: any object whose `inspect` omits
  distinguishing state collides.

The collision is not reachable through the documented scalar/`ssl:`-hash API,
but it is reachable today through the supported `ssl_context:` option, so it is
a real credential-isolation hole.

## Decisions

1. **Case A now:** refuse to key any option value that is not safely,
   canonically serializable. Raise `OptionKeyError` at key-derivation time
   (before any pool is created or socket opened). This makes credential mixing
   impossible rather than merely unlikely.
2. **Case C later (documented, not built):** replace `.inspect` with a
   canonical recursive serializer. That would let us *restore* `ssl_context:`
   support by digesting the context's actual security material, and remove the
   `OptionKeyError` rejection for it. See "Future work".
3. **Request-body errors pass through (option B):** `Pool#with` yields a session
   and the caller makes the request inside the block. Errors from the caller's
   own `conn.get(...)` (`HTTP::*`, and any Ruby core I/O error they trigger)
   propagate **raw**. We do not re-wrap them — we do not own request semantics
   the caller chose. We wrap only failures we own: checkout timeout, closed
   pool, pool-limit, URL validation, and option-keyability.
4. **Core errors stay core:** genuine programmer-contract violations
   (`max_pools must be >= 1`, `Registry.configure` after init) remain Ruby
   `ArgumentError` / `RuntimeError`. They are not pool-domain errors and Ruby's
   own classes communicate them best.

## Error hierarchy

New file `lib/http_connection_pool/errors.rb`, required before `pool.rb` /
`registry.rb`:

```
HttpConnectionPool::Error < StandardError          # unified root
├── ConfigurationError      # unusable setup, raised before any I/O
│   ├── InvalidURLError     # bad/missing scheme, unsupported scheme, no host
│   └── OptionKeyError      # option value cannot be safely used as a pool key
├── PoolLimitError          # new pool would exceed max_pools
├── TimeoutError            # no connection available within checkout timeout
└── ClosedError             # #with called on a closed pool
```

Backward-compatible aliases keep the existing constant paths working so no
external `rescue` (or current spec) breaks:

```ruby
# in pool.rb
class Pool
  TimeoutError = HttpConnectionPool::TimeoutError
  ClosedError  = HttpConnectionPool::ClosedError
end

# in registry.rb
class Registry
  PoolLimitError = HttpConnectionPool::PoolLimitError
end
```

Every error class carries only non-sensitive context in its message (origin,
option *key paths*, classes — never option *values*), consistent with the
existing credential-redaction rule.

## Where each error is raised

| Error            | Raised from                                   | Replaces / status        |
| ---------------- | --------------------------------------------- | ------------------------ |
| `InvalidURLError`| `Registry#extract_origin`                     | 3× raw `ArgumentError`   |
| `OptionKeyError` | keyability guard inside `Registry#pool_key`   | new (silent today)       |
| `PoolLimitError` | `Registry#ensure_within_limit!`               | re-parented + aliased    |
| `TimeoutError`   | `Pool#with` (checkout timeout)                | re-parented + aliased    |
| `ClosedError`    | `Pool#with` (closed / shutting down)          | re-parented + aliased    |
| `ArgumentError`  | `Registry#initialize` (`max_pools`)           | unchanged (core)         |
| `RuntimeError`   | `Registry.configure` (already initialised)    | unchanged (core)         |

`OptionKeyError` guards **both** `pool_for` and `release`, since both derive a
key via `pool_key`. A `release` with an unkeyable option raises rather than
silently no-op'ing — consistent with the fact that such an option could never
have created a pool.

## Safe keying (OptionKeyError behavior)

A guard validates every value reachable in the options structure before
hashing. Safe-to-key types, checked recursively:

- `String`, `Symbol`, `Integer`, `Float`, `TrueClass`, `FalseClass`, `NilClass`
- `Hash` / `Array` whose members are all safe-to-key

Anything else (an `SSLContext`, an `OpenSSL::PKey`, a proc, an arbitrary object)
raises:

```ruby
raise OptionKeyError,
      "option #{key_path} is a #{value.class} and cannot be used as a pool key; " \
      'pass SSL material via the `ssl:` hash (e.g. ssl: { ca_file: ... }), or ' \
      'give each distinct context its own Connectable subclass / explicit pool'
```

- The message names the offending **key path** and **class**, never the value.
- `ssl:` (a hash of scalars) remains fully supported for keying and for
  `Pool#build_connection`.
- `ssl_context:` (an object) now raises `OptionKeyError`. This is a deliberate,
  temporary regression of the `ssl_context:` build path added in the http v6
  fix: silent credential mixing is worse than an explicit "use `ssl:`". A code
  comment at the guard and the "Future work" section below record that case C
  is the path to restoring it.

## Request-body error pass-through (option B)

`Pool#with` continues to translate only checkout-level failures:

- `ConnectionPool::TimeoutError` → `HttpConnectionPool::TimeoutError`
- `ConnectionPool::PoolShuttingDownError` / closed guard →
  `HttpConnectionPool::ClosedError`

Errors raised inside the caller's block — `HTTP::Error` and its subclasses,
`HTTP::TimeoutError`, `HTTP::ConnectionError`, or any Ruby core error the
caller's request triggers — propagate unchanged. Callers rescue
`HttpConnectionPool::Error` for pool/registry failures and `HTTP::Error` for
request failures. This is documented explicitly so the split is not surprising.

## Testing (TDD, all offline/stubbed)

New `spec/http_connection_pool/errors_spec.rb`:

- every concrete error is `< HttpConnectionPool::Error`;
- `ConfigurationError` subclasses are `< ConfigurationError`;
- legacy aliases resolve to the new classes
  (`HttpConnectionPool::Pool::TimeoutError`
  `.equal?(HttpConnectionPool::TimeoutError)`, etc.);
- a single `rescue HttpConnectionPool::Error` catches timeout, closed,
  pool-limit, invalid-URL, and option-key errors.

`registry_spec.rb` additions:

- `OptionKeyError` raised for `ssl_context:` (an `SSLContext`) and for a generic
  non-keyable object, from **both** `pool_for` and `release`;
- the message includes the option key path and class, and **excludes** a known
  secret value (assert the secret string is absent from `error.message`);
- collision regression: two option sets that differ only in an unkeyable object
  cannot share a key — guaranteed because the unkeyable value raises rather than
  hashing;
- `InvalidURLError` replaces the prior `ArgumentError` expectations for missing
  scheme, unsupported scheme, and missing host.

`pool_spec.rb` change:

- the existing `ssl_context:` real-build example becomes an `OptionKeyError`
  example; the `ssl:` hash real-build example stays green.

## Documentation

- **README:** add an "Error handling" subsection — the hierarchy, the
  single-rescue pattern, and the explicit statement that request-body `HTTP::*`
  errors propagate raw. Update the configuration-options table and the v6 SSL
  note: `ssl_context:` now raises `OptionKeyError`; use the `ssl:` hash.
- **CLAUDE.md:** update the Error Classes section with the new hierarchy and the
  option-keyability rule.
- Both updated in the same change as the code (standing CLAUDE.md instruction).

## Future work (case C — not in this plan)

Replace `Object#inspect` in `pool_key` with a canonical, injective recursive
serializer (deterministic encoding of type + value, raising on anything it
cannot canonically encode). Benefits:

- removes the reliance on `inspect` being injective for the safe-to-key types;
- enables **restoring `ssl_context:` support** by deriving the digest from the
  context's actual security-relevant material (cert, private key, `ca_file`,
  verify_mode, verify_hostname, ciphers) instead of rejecting it — at which
  point the `OptionKeyError` rejection for `ssl_context:` is lifted.

Recorded here and in a code comment at the keyability guard so the temporary
`ssl_context:` rejection is understood as deliberate, not an oversight.

## Out of scope

- Wrapping request-body `HTTP::*` errors (rejected: option B — we do not own
  request semantics).
- Folding core `ArgumentError`/`RuntimeError` programmer-contract violations
  into the hierarchy (rejected: core classes communicate these best).
- Building the canonical serializer (case C — documented above, deferred).

## Verification

`bundle exec rake ci` (bundler-audit → RuboCop → RSpec) must stay green. The new
and changed specs must pass deterministically.
