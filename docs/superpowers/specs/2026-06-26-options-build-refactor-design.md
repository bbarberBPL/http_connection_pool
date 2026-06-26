# Options build refactor — design

## Goal

Refactor `Pool#build_connection` to construct connections through a single
`HTTP::Options` object rather than a chain of `HTTP.persistent(...).timeout.headers.auth.via`
calls. This gives one uniform, correct build path for everything http.rb models
as a first-class option (headers, auth, ssl, persistent origin), keeps the
chainable API only for the two options http.rb genuinely translates (timeout,
proxy), and lets us deep-freeze pool options so a pool's configuration cannot
mutate after creation. `ssl_context` building is made correct (Options accepts
it natively) but remains rejected at the registry keying boundary; resolving
that (case C) is deferred with documented reasons.

The primary motivation is **correctness and uniformity of the build path**
(option A from brainstorming). Immutability and the `ssl_context` building fix
come along as part of doing it right.

This is an MRI-tested gem with no Rails runtime dependency; this change adds no
new runtime dependency and touches only `lib/http_connection_pool/pool.rb` plus
specs and docs.

## Background — what the http.rb v6 source establishes

Read from the installed `http-6.0.3` source:

- `HTTP::Options.new(**kwargs)` accepts `headers:`, `ssl:`, `ssl_context:`,
  `proxy:`, and `persistent:` as first-class keyword fields. `persistent=`
  normalizes its value to the URL origin.
- `HTTP::Session.new(options)` accepts an `HTTP::Options` (or kwargs) and is the
  object `HTTP.persistent` and every chainable method ultimately build.
- `auth(value)` is sugar: it calls `headers(Authorization => value.to_s)`. So
  `auth` is just a header.
- `timeout(value)` is NOT a direct option — the chainable translates a
  number/hash into `timeout_class` + `timeout_options` via the private
  `resolve_timeout_hash`. `proxy` similarly is built from positional args by the
  private `build_proxy_hash`. Reproducing those ourselves would couple us to
  http.rb private internals, so we keep using the chainable for these two.
- `HTTP::Options` does not freeze itself or its nested hashes.
- `persistent:` set as a direct Options field produces an identical result to
  chaining `.persistent(origin)` (both run through the same `persistent=`
  setter). Verified empirically.

## Decisions

1. **Build via one `HTTP::Options`** for the directly-mappable fields, with
   `persistent: @origin` set as a field (not chained).
2. **Keep `timeout`/`proxy` on the chainable** (`apply_chainable`), since
   http.rb intentionally translates them and the translation helpers are private.
3. **`apply_chainable` early-returns** the session untouched when neither
   `timeout` nor `proxy` is set (the common case), avoiding needless allocations.
4. **Fold `auth` into headers** as an `Authorization` header, matching what
   http.rb does internally.
5. **Omit `ssl_context` from the built options for now**, with a `# TODO`
   pointing at case C. It is already rejected at the registry keying boundary
   (an `SSLContext` cannot be safely used as a pool key), so it never reaches
   `build_connection` through the supported path; wiring it would be dead code.
6. **Deep-freeze `@options`** (the hash, nested hashes/arrays, and string
   values) in `Pool#initialize` so a pool's configuration is immutable.
7. **Do not set `base_uri`** (brainstorming option A). The pool keys on origin
   (scheme+host+port); http.rb's `persistent` already resolves relative request
   paths against that origin. A path-prefix `base_uri` would conflict with
   origin-keying (same origin, different prefix would share a pool), so it stays
   a request-time concern. We verify and document the relative-path behavior.

## The build path

```ruby
def build_connection
  session = HTTP::Session.new(HTTP::Options.new(**native_options))
  apply_chainable(session)
end

# Directly-mappable HTTP::Options fields, including persistent (= origin).
# auth is folded into headers as an Authorization header (matching http.rb).
def native_options
  opts = { persistent: @origin, headers: headers_with_auth }
  opts[:ssl] = @options[:ssl] if @options[:ssl]
  # TODO (case C): when ssl_context becomes safely keyable (see
  # docs/superpowers/specs/2026-06-25-error-handling-design.md), set
  # opts[:ssl_context] = @options[:ssl_context] here. It is currently rejected
  # at the registry keying boundary, so it never reaches this method.
  opts
end

# Merge auth into the headers hash as an Authorization header.
def headers_with_auth
  headers = @options[:headers] || {}
  return headers unless @options[:auth]

  headers.merge('Authorization' => @options[:auth])
end

# timeout/proxy need http.rb's own translation, so they stay chainable.
# Early-return when neither is set (the common case) to avoid extra allocations.
def apply_chainable(session)
  return session unless @options[:timeout] || @options[:proxy]

  session = session.timeout(@options[:timeout]) if @options[:timeout]
  session = session.via(*@options[:proxy])      if @options[:proxy]
  session
end
```

Note: `headers_with_auth` must not mutate the caller's headers hash (and after
deep-freeze it could not) — `merge` returns a new hash, which is correct.

## Deep freezing

In `Pool#initialize`, replace the shallow `@options.freeze` with a recursive
freeze:

```ruby
def deep_freeze(obj)
  case obj
  when Hash  then obj.each { |k, v| deep_freeze(k); deep_freeze(v) }
  when Array then obj.each { |v| deep_freeze(v) }
  end
  obj.freeze
end
```

Applied as `@options = deep_freeze(options)`. The registry's keyability guard
already proves options are scalars or hashes/arrays of scalars before a pool is
built, so `deep_freeze` only ever meets freezable structures. Frozen options
also reinforce credential isolation: the hash hashed into the SHA-256 key cannot
later diverge from what the pool uses.

## Testing (TDD, offline/stubbed)

In `spec/http_connection_pool/pool_spec.rb`, extend the existing
"building real connections (http v6 integration)" block (it already un-stubs
`HTTP.persistent`):

- a bare origin yields a persistent `HTTP::Session`;
- `default_options.persistent` equals the origin (proves persistent is set as a
  field, not chained);
- `headers:` land as headers; `auth:` lands as an `Authorization` header;
  `auth:` combined with explicit `headers:` merges rather than clobbers;
- `ssl:` hash applies without error;
- `timeout:` and `proxy:` apply without error;
- the early-return path (no timeout/proxy) yields a usable session.

Deep-freeze examples (no real http needed):

- after `Pool.new(...)`, `@options` is frozen; a nested `headers` hash and a
  nested array are frozen; mutating any raises `FrozenError`.

Relative-path resolution (the base_uri verification):

- assert at the `HTTP::Options`/request-builder level that a relative request
  path resolves against the persistent origin — deterministic and offline, no
  network call.

## Documentation

- **README** — reframe the configuration-options section: most options are set
  on the underlying `HTTP::Options` when the session is built (`headers`,
  `auth`→Authorization header, `ssl`, `persistent`=origin); `timeout`/`proxy`
  use http.rb's chainable translation. Keep the `ssl_context` → `OptionKeyError`
  note and refresh its deferred-resolution wording (write-only TLS fields).
  Add a note that request paths resolve against `base_url`'s origin.
- **docs/superpowers/specs/2026-06-25-error-handling-design.md** (living design
  doc, owns case C) — update case C with the empirical finding: automatic
  `SSLContext` fingerprinting is unsafe because `min_version`/`max_version` are
  write-only and C-level options are not introspectable, so any readable-state
  digest would reintroduce the collision. Record the two viable future routes:
  a caller-supplied key discriminator, or wrapping `SSLContext` construction to
  capture what the caller set.
- **CLAUDE.md** — note the `HTTP::Options`-based build path and that pool
  options are deep-frozen.
- **Examples** — `examples/solr_client.rb` and `examples/solr_update_demo.rb`:
  a language/accuracy pass so comments match the new build-path vocabulary and
  nothing claims the old chained-options behavior. The Solr client already uses
  `headers` via `pool_options` and relative paths, so behavior is unchanged.
- **Code comment** — the `# TODO` at the omitted `ssl_context` field, pointing
  at the case-C section.

## Prerequisite for Solr work (USER ACTION REQUIRED)

The local Solr 8.11.x instance (core `curator_development`, port 8983) is not
always running. **Before any task refactors or live-tests
`examples/solr_client.rb` / `examples/solr_update_demo.rb`, the implementer must
pause and ask the user to start Solr first** — do not assume it is up, and do
not silently skip the live verification. A documentation/comment-only pass over
the example files does not require Solr; only running the demo against the live
instance does.

## Out of scope

- Resolving case C (keyable `ssl_context`) — deferred; the build path is made
  correct, but keying rejection stays. Documented above.
- Reimplementing http.rb's private timeout/proxy translation (rejected — keep
  the chainable for those two).
- Adding a per-pool `base_uri`/path-prefix (rejected — conflicts with
  origin-keying).

## Verification

`bundle exec rake ci` (bundler-audit → RuboCop → RSpec) must stay green. The
Solr example, if exercised live, requires the user to start Solr first (see
prerequisite).
