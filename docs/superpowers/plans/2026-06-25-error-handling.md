# Error Handling and Safe Pool Keying Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a unified `HttpConnectionPool::Error` hierarchy and an `OptionKeyError` guard that refuses to key non-canonically-serializable option values (closing a silent `ssl_context:` collision/fragmentation), while leaving request-body `HTTP::*` errors to propagate raw.

**Architecture:** A new `errors.rb` defines the hierarchy; the existing `Pool::TimeoutError`/`Pool::ClosedError`/`Registry::PoolLimitError` constants become aliases to the new classes so no existing `rescue` breaks. `Registry#extract_origin` raises `InvalidURLError`; `Registry#pool_key` runs a recursive keyability guard that raises `OptionKeyError`. `Pool#with` keeps translating only checkout-level failures.

**Tech Stack:** Ruby (MRI), RSpec, RuboCop, http.rb v6, connection_pool, concurrent-ruby.

## Global Constraints

- Tested on MRI (CRuby); JRuby planned but untested. No new runtime dependency.
- Every Ruby file begins with `# frozen_string_literal: true`. All non-interpolated strings use single quotes.
- Error messages may include origin, option *key paths*, and *classes* — **never** option *values* (credential-redaction rule).
- No apostrophes inside RSpec `it`/`describe`/`context` strings (Ruby SyntaxError).
- `RSpec/MultipleExpectations: Max: 3`, `RSpec/ExampleLength: Max: 20`.
- `bundle exec rubocop` must be clean; run `bundle exec rubocop -a` to auto-fix. No inline `# rubocop:disable` unless unavoidable.
- `bundle exec rake ci` (bundler-audit → RuboCop → RSpec) must be green before any commit.
- **Git:** add files BY NAME, never `-A`/`.`. `Gemfile.lock` is gitignored — never stage it. Do NOT `git push` (user-only). End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Update README.md and CLAUDE.md in the same change as the behaviour (standing instruction).
- `ssl_context:` raising `OptionKeyError` is a deliberate, documented temporary regression; the `ssl:` hash path must keep working. Case C (canonical serializer) is future work, not in this plan.

---

### Task 1: Error hierarchy and backward-compatible aliases

**Files:**
- Create: `lib/http_connection_pool/errors.rb`
- Modify: `lib/http_connection_pool.rb` (require errors first)
- Modify: `lib/http_connection_pool/pool.rb` (require errors; replace the two error class definitions with aliases)
- Modify: `lib/http_connection_pool/registry.rb` (require errors; replace PoolLimitError definition with an alias)
- Test: `spec/http_connection_pool/errors_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `HttpConnectionPool::Error < StandardError`
  - `HttpConnectionPool::ConfigurationError < Error`
  - `HttpConnectionPool::InvalidURLError < ConfigurationError`
  - `HttpConnectionPool::OptionKeyError < ConfigurationError`
  - `HttpConnectionPool::PoolLimitError < Error`
  - `HttpConnectionPool::TimeoutError < Error`
  - `HttpConnectionPool::ClosedError < Error`
  - Aliases: `Pool::TimeoutError`, `Pool::ClosedError`, `Registry::PoolLimitError` all `.equal?` their new top-level counterparts.

- [ ] **Step 1: Write the failing test**

Create `spec/http_connection_pool/errors_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'HttpConnectionPool error hierarchy' do
  it 'roots every pool error at HttpConnectionPool::Error' do
    [HttpConnectionPool::PoolLimitError,
     HttpConnectionPool::TimeoutError,
     HttpConnectionPool::ClosedError,
     HttpConnectionPool::ConfigurationError,
     HttpConnectionPool::InvalidURLError,
     HttpConnectionPool::OptionKeyError].each do |klass|
      expect(klass.ancestors).to include(HttpConnectionPool::Error)
    end
  end

  it 'groups configuration errors under ConfigurationError' do
    expect(HttpConnectionPool::InvalidURLError.ancestors)
      .to include(HttpConnectionPool::ConfigurationError)
    expect(HttpConnectionPool::OptionKeyError.ancestors)
      .to include(HttpConnectionPool::ConfigurationError)
  end

  it 'keeps the legacy Pool and Registry constants as aliases' do
    expect(HttpConnectionPool::Pool::TimeoutError)
      .to equal(HttpConnectionPool::TimeoutError)
    expect(HttpConnectionPool::Pool::ClosedError)
      .to equal(HttpConnectionPool::ClosedError)
    expect(HttpConnectionPool::Registry::PoolLimitError)
      .to equal(HttpConnectionPool::PoolLimitError)
  end

  it 'lets a single rescue catch any pool-layer error' do
    caught = []
    [HttpConnectionPool::TimeoutError, HttpConnectionPool::ClosedError,
     HttpConnectionPool::PoolLimitError, HttpConnectionPool::InvalidURLError,
     HttpConnectionPool::OptionKeyError].each do |klass|
      raise klass, 'boom'
    rescue HttpConnectionPool::Error => e
      caught << e.class
    end
    expect(caught.length).to eq(5)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/http_connection_pool/errors_spec.rb`
Expected: FAIL — `NameError: uninitialized constant HttpConnectionPool::Error` (or `OptionKeyError`).

- [ ] **Step 3: Create the errors file**

Create `lib/http_connection_pool/errors.rb`:

```ruby
# frozen_string_literal: true

module HttpConnectionPool
  # Root of every error raised by this gem's pool/registry layer. Rescue this to
  # catch any failure that originates here. Request-body errors from http.rb
  # (HTTP::Error and subclasses) are NOT remapped — they propagate raw, since a
  # request made inside a `with`/`with_connection` block is the caller's own.
  class Error < StandardError; end

  # Unusable configuration, detected before any I/O (URL validation, option
  # keyability). All ConfigurationError subclasses are raised at setup time.
  class ConfigurationError < Error; end

  # A URL had no scheme, an unsupported scheme, or no host.
  class InvalidURLError < ConfigurationError; end

  # An option value cannot be safely/canonically used as part of a pool key
  # (e.g. an SSLContext object, whose inspect omits distinguishing material and
  # would silently collide). See README "Error handling".
  class OptionKeyError < ConfigurationError; end

  # Creating a new pool would exceed the registry's max_pools cap.
  class PoolLimitError < Error; end

  # No connection became available within the checkout timeout.
  class TimeoutError < Error; end

  # A pool was used after it was closed.
  class ClosedError < Error; end
end
```

- [ ] **Step 4: Require errors first in the entry point**

In `lib/http_connection_pool.rb`, add the errors require immediately after the version require:

```ruby
# frozen_string_literal: true

require_relative 'http_connection_pool/version'
require_relative 'http_connection_pool/errors'
require_relative 'http_connection_pool/pool'
require_relative 'http_connection_pool/registry'
require_relative 'http_connection_pool/connectable'
```

- [ ] **Step 5: Replace Pool error definitions with aliases**

In `lib/http_connection_pool/pool.rb`, add `require_relative 'errors'` near the other requires at the top (after the existing `require` lines, before `module HttpConnectionPool`):

```ruby
require_relative 'errors'
```

Then replace the two class definitions:

```ruby
    # Raised when no connection becomes available within the timeout.
    class TimeoutError < StandardError; end

    # Raised when the pool is used after it has been closed.
    class ClosedError < StandardError; end
```

with aliases to the canonical classes:

```ruby
    # Backward-compatible aliases — the canonical classes live in errors.rb
    # under HttpConnectionPool. Existing `rescue Pool::TimeoutError` keeps working.
    TimeoutError = HttpConnectionPool::TimeoutError
    ClosedError  = HttpConnectionPool::ClosedError
```

- [ ] **Step 6: Replace the Registry PoolLimitError definition with an alias**

In `lib/http_connection_pool/registry.rb`, add `require_relative 'errors'` alongside the existing requires at the top (e.g. after `require 'uri'`):

```ruby
require_relative 'errors'
```

Then replace:

```ruby
    # Raised when creating a new pool would exceed the configured max_pools cap.
    class PoolLimitError < StandardError; end
```

with:

```ruby
    # Backward-compatible alias — canonical class lives in errors.rb.
    PoolLimitError = HttpConnectionPool::PoolLimitError
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bundle exec rspec spec/http_connection_pool/errors_spec.rb`
Expected: PASS (4 examples).

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb spec/http_connection_pool/registry_spec.rb`
Expected: PASS — the alias change must not break any existing pool/registry spec (they reference `Pool::TimeoutError` etc., which now resolve to the new classes).

- [ ] **Step 8: RuboCop**

Run: `bundle exec rubocop lib/http_connection_pool/errors.rb lib/http_connection_pool.rb lib/http_connection_pool/pool.rb lib/http_connection_pool/registry.rb spec/http_connection_pool/errors_spec.rb`
Expected: no offenses (auto-fix with `-a` if any).

- [ ] **Step 9: Commit**

```bash
git add lib/http_connection_pool/errors.rb lib/http_connection_pool.rb lib/http_connection_pool/pool.rb lib/http_connection_pool/registry.rb spec/http_connection_pool/errors_spec.rb
git commit -m "$(cat <<'EOF'
Add unified HttpConnectionPool::Error hierarchy with legacy aliases

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: InvalidURLError from extract_origin

**Files:**
- Modify: `lib/http_connection_pool/registry.rb` (`extract_origin`)
- Modify: `spec/http_connection_pool/registry_spec.rb` (update expectations)

**Interfaces:**
- Consumes: `HttpConnectionPool::InvalidURLError` (Task 1).
- Produces: `extract_origin` raises `InvalidURLError` (a `ConfigurationError`, still also rescuable as `HttpConnectionPool::Error`) instead of `ArgumentError`.

- [ ] **Step 1: Find the current URL-validation expectations**

Run: `grep -n "scheme\|must have a host\|unsupported scheme\|ArgumentError" spec/http_connection_pool/registry_spec.rb`
Expected: locate the examples asserting `ArgumentError` for bad URLs. Note their line numbers.

- [ ] **Step 2: Write/adjust the failing test**

In `spec/http_connection_pool/registry_spec.rb`, change the URL-validation examples to expect `HttpConnectionPool::InvalidURLError`. The three cases must read (rephrase any existing ones to match):

```ruby
    it 'raises InvalidURLError when the scheme is missing' do
      expect { described_class.new.pool_for('api.example.com') }
        .to raise_error(HttpConnectionPool::InvalidURLError, /scheme/)
    end

    it 'raises InvalidURLError for an unsupported scheme' do
      expect { described_class.new.pool_for('ftp://api.example.com') }
        .to raise_error(HttpConnectionPool::InvalidURLError, /unsupported scheme/)
    end

    it 'raises InvalidURLError when the host is missing' do
      expect { described_class.new.pool_for('https://') }
        .to raise_error(HttpConnectionPool::InvalidURLError, /host/)
    end
```

If equivalent examples already exist asserting `ArgumentError`, replace their error class with `HttpConnectionPool::InvalidURLError` rather than adding duplicates.

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/http_connection_pool/registry_spec.rb -e InvalidURLError`
Expected: FAIL — the code still raises `ArgumentError`, so `raise_error(HttpConnectionPool::InvalidURLError)` is not matched.

- [ ] **Step 4: Update extract_origin**

In `lib/http_connection_pool/registry.rb`, replace the three raises in `extract_origin`:

```ruby
      uri = URI.parse(url)
      raise ArgumentError, "URL must have a scheme (http/https): #{url}" unless uri.scheme
      raise ArgumentError, "unsupported scheme: #{uri.scheme}"           unless SUPPORTED_SCHEMES.include?(uri.scheme)
      raise ArgumentError, "URL must have a host: #{url}"                unless uri.host
```

with:

```ruby
      uri = URI.parse(url)
      raise InvalidURLError, "URL must have a scheme (http/https): #{url}" unless uri.scheme
      raise InvalidURLError, "unsupported scheme: #{uri.scheme}"           unless SUPPORTED_SCHEMES.include?(uri.scheme)
      raise InvalidURLError, "URL must have a host: #{url}"                unless uri.host
```

(`InvalidURLError` resolves to `HttpConnectionPool::InvalidURLError` from inside the `Registry` class via the enclosing module.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/http_connection_pool/registry_spec.rb`
Expected: PASS (all examples, including the updated three).

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop lib/http_connection_pool/registry.rb spec/http_connection_pool/registry_spec.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add lib/http_connection_pool/registry.rb spec/http_connection_pool/registry_spec.rb
git commit -m "$(cat <<'EOF'
Raise InvalidURLError from extract_origin instead of ArgumentError

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: OptionKeyError keyability guard in pool_key

**Files:**
- Modify: `lib/http_connection_pool/registry.rb` (`pool_key`, add `ensure_keyable!` + constant)
- Modify: `spec/http_connection_pool/registry_spec.rb` (new keyability examples)

**Interfaces:**
- Consumes: `HttpConnectionPool::OptionKeyError` (Task 1).
- Produces: `pool_key` raises `OptionKeyError` for any option value (recursively) that is not a `String`, `Symbol`, `Integer`, `Float`, `true`, `false`, `nil`, or a `Hash`/`Array` of such. Guard runs for both `pool_for` and `release` (both call `pool_key`).

- [ ] **Step 1: Write the failing tests**

In `spec/http_connection_pool/registry_spec.rb`, add a new describe block (place it near the existing keying/options examples):

```ruby
  describe 'option keyability guard' do
    let(:registry) { described_class.new }

    after { registry.close_all }

    it 'raises OptionKeyError when an option value is not safely keyable' do
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      expect { registry.pool_for('https://api.example.com', ssl_context: ctx) }
        .to raise_error(HttpConnectionPool::OptionKeyError, /ssl_context/)
    end

    it 'names the offending option and its class but not any value' do
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      registry.pool_for('https://api.example.com',
                        headers: { 'Authorization' => 'SECRET-TOKEN' },
                        ssl_context: ctx)
    rescue HttpConnectionPool::OptionKeyError => e
      expect(e.message).to include('ssl_context', 'SSLContext')
      expect(e.message).not_to include('SECRET-TOKEN')
    end

    it 'guards release as well as pool_for' do
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      expect { registry.release('https://api.example.com', ssl_context: ctx) }
        .to raise_error(HttpConnectionPool::OptionKeyError)
    end

    it 'still accepts the ssl hash and other scalar options' do
      expect do
        pool = registry.pool_for('https://api.example.com',
                                 ssl: { verify_mode: 0 },
                                 headers: { 'Accept' => 'application/json' })
        expect(pool).to be_a(HttpConnectionPool::Pool)
      end.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/http_connection_pool/registry_spec.rb -e 'option keyability'`
Expected: FAIL — without the guard, `pool_for(..., ssl_context: ctx)` builds a pool (no error), so the `raise_error(OptionKeyError)` examples fail. (The "still accepts the ssl hash" example already passes.)

- [ ] **Step 3: Add the keyability guard**

In `lib/http_connection_pool/registry.rb`, add a constant near the top of the class (after `SUPPORTED_SCHEMES`):

```ruby
    # Option values that can be canonically serialized into a pool key. Anything
    # else (an SSLContext, a PKey, a proc, an arbitrary object) is rejected by
    # ensure_keyable! rather than risking a silent inspect-based collision.
    # FUTURE (case C): a canonical serializer would let us key these safely —
    # e.g. restore ssl_context: by digesting its real security material — and
    # remove this rejection. See docs/superpowers/specs/2026-06-25-error-handling-design.md.
    KEYABLE_SCALARS = [String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].freeze
```

Update `pool_key` to call the guard first:

```ruby
    def pool_key(origin, options)
      ensure_keyable!(options)
      Digest::SHA256.hexdigest("#{origin}|#{normalize_options(options).inspect}")
    end
```

Add the private guard method (place it next to `normalize_options`):

```ruby
    # Reject any option value that cannot be canonically serialized for keying.
    # The path is built from option *keys* (option names like :ssl_context),
    # never values, so the message cannot leak credential material.
    def ensure_keyable!(value, path = 'options')
      case value
      when *KEYABLE_SCALARS
        nil
      when Hash
        value.each do |k, v|
          ensure_keyable!(k, "#{path} key")
          ensure_keyable!(v, "#{path}[#{k.inspect}]")
        end
      when Array
        value.each_with_index { |v, i| ensure_keyable!(v, "#{path}[#{i}]") }
      else
        raise OptionKeyError,
              "option #{path} is a #{value.class} and cannot be used as a pool key; " \
              'pass SSL material via the `ssl:` hash (e.g. ssl: { ca_file: ... }), or ' \
              'give each distinct context its own Connectable subclass / explicit pool'
      end
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/http_connection_pool/registry_spec.rb -e 'option keyability'`
Expected: PASS (4 examples).

- [ ] **Step 5: Run the full registry + pool spec to check for regressions**

Run: `bundle exec rspec spec/http_connection_pool/registry_spec.rb spec/http_connection_pool/pool_spec.rb`
Expected: PASS for registry. `pool_spec.rb` may now FAIL on the existing `ssl_context:` real-build example — that is expected and is fixed in Task 4. If pool_spec fails only on the `ssl_context` example, proceed; otherwise investigate.

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop lib/http_connection_pool/registry.rb spec/http_connection_pool/registry_spec.rb`
Expected: no offenses. If `Metrics/MethodLength` flags `ensure_keyable!`, it is under 20 lines as written; do not add a disable.

- [ ] **Step 7: Commit**

```bash
git add lib/http_connection_pool/registry.rb spec/http_connection_pool/registry_spec.rb
git commit -m "$(cat <<'EOF'
Reject non-keyable option values with OptionKeyError

Closes a silent ssl_context: collision/fragmentation: inspect-based keying
could map different credentials to the same SHA-256 key. The guard rejects any
option value that is not a scalar or a hash/array of scalars, naming the option
and its class (never its value). Guards both pool_for and release.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Update pool_spec for the ssl_context regression

**Files:**
- Modify: `spec/http_connection_pool/pool_spec.rb` (the real-build SSL examples)

**Interfaces:**
- Consumes: `HttpConnectionPool::OptionKeyError` (Task 1), the guard (Task 3).
- Produces: pool_spec green again, with `ssl_context:` asserted to raise and `ssl:` hash asserted to build.

Note: `Pool.new(..., ssl_context: ctx)` constructs a pool directly (no registry, no `pool_key`), so the Pool layer itself does not raise `OptionKeyError` — the guard lives in the Registry. The existing `pool_spec.rb` "building real connections" example constructs `Pool` directly and calls `build_connection`, which seeds `ssl_context` into the session successfully. That example therefore still passes at the Pool layer. The behaviour change (rejection) is at the Registry boundary.

- [ ] **Step 1: Inspect the current SSL examples**

Run: `grep -n "ssl_context\|ssl hash\|building real connections" spec/http_connection_pool/pool_spec.rb`
Expected: find the `ssl_context` and `ssl` real-build examples added previously.

- [ ] **Step 2: Decide the correct assertion and update**

The Pool layer still accepts `ssl_context:` (only the Registry rejects it). To keep the spec accurate and document where rejection happens, change the Pool-level `ssl_context` example into a Registry-level rejection example, and keep the Pool-level `ssl:` example.

Replace the existing `ssl_context` real-build example:

```ruby
    it 'applies an ssl_context option (regression: .ssl chainable was removed in v6)' do
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      conn = build(ssl_context: ctx)
      expect(conn).to be_a(HTTP::Session)
      expect(conn.default_options.ssl_context).to be(ctx)
    end
```

with a comment-only note plus a registry-boundary expectation:

```ruby
    # ssl_context: is rejected at the Registry boundary (OptionKeyError) because
    # an SSLContext cannot be safely used as a pool key. Pool.new itself does not
    # key options, so a directly-constructed pool can still seed ssl_context into
    # the session — but the supported path is the registry, so we assert the
    # rejection there rather than encouraging the direct-construction path.
    it 'rejects ssl_context at the registry boundary with OptionKeyError' do
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      registry = HttpConnectionPool::Registry.new
      expect { registry.pool_for(origin, ssl_context: ctx) }
        .to raise_error(HttpConnectionPool::OptionKeyError)
    ensure
      registry&.close_all
    end
```

Keep the existing `ssl:` hash example unchanged (it must still pass):

```ruby
    it 'applies an ssl hash option without error' do
      conn = build(ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
      expect(conn).to be_a(HTTP::Session)
      expect(conn.persistent?).to be true
    end
```

- [ ] **Step 3: Run pool_spec to verify it passes**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 4: RuboCop**

Run: `bundle exec rubocop spec/http_connection_pool/pool_spec.rb`
Expected: no offenses.

- [ ] **Step 5: Commit**

```bash
git add spec/http_connection_pool/pool_spec.rb
git commit -m "$(cat <<'EOF'
Update pool_spec: ssl_context now rejected at the registry boundary

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Documentation — README and CLAUDE.md

**Files:**
- Modify: `README.md` (new "Error handling" subsection; options table + v6 SSL note)
- Modify: `CLAUDE.md` (Error Classes section)

**Interfaces:**
- Consumes: the full error hierarchy and the keyability behaviour (Tasks 1–4).
- Produces: living docs matching the shipped behaviour.

- [ ] **Step 1: Add the README "Error handling" subsection**

In `README.md`, add a new `## Error handling` section (place it after the `## Security` section). Use this content:

```markdown
## Error handling

Every error raised by the pool/registry layer descends from a single root, so
one rescue catches them all:

| Error                                  | Raised when                                      |
| -------------------------------------- | ------------------------------------------------ |
| `HttpConnectionPool::TimeoutError`     | No connection available within the checkout timeout |
| `HttpConnectionPool::ClosedError`      | A closed pool is used                            |
| `HttpConnectionPool::PoolLimitError`   | A new pool would exceed `max_pools`              |
| `HttpConnectionPool::InvalidURLError`  | A URL has no/unsupported scheme or no host       |
| `HttpConnectionPool::OptionKeyError`   | An option value cannot be used as a pool key     |

`InvalidURLError` and `OptionKeyError` are both `ConfigurationError`, which is
itself a `HttpConnectionPool::Error`:

```ruby
begin
  client.with_connection { |conn| conn.get('/status') }
rescue HttpConnectionPool::Error => e
  # any pool/registry-layer failure
end
```

The legacy constants `Pool::TimeoutError`, `Pool::ClosedError`, and
`Registry::PoolLimitError` still work — they are aliases of the classes above.

**Request errors pass through.** A request you make inside the block
(`conn.get(...)`) is yours: any `HTTP::Error` (timeouts, connection failures,
status errors) propagates **unchanged**, because the pool does not own your
request semantics. Rescue `HttpConnectionPool::Error` for pool/registry
failures and `HTTP::Error` for request failures.
```

- [ ] **Step 2: Update the options table and v6 SSL note for ssl_context**

In `README.md`, in the configuration-options section, replace the existing v6 SSL note block with:

```markdown
> **Note (http.rb v6):** the chainable `.ssl` method was removed in http v6, so
> `:ssl` is seeded into the session's options *before* it is made persistent.
> The `:ssl_context` option is currently **not supported** — an `SSLContext`
> object cannot be safely used as a pool key (different contexts can share a
> key), so passing it raises `HttpConnectionPool::OptionKeyError`. Configure TLS
> via the `:ssl` hash (`ssl: { ca_file: ..., verify_mode: ... }`) instead.
```

If the options table lists an `:ssl_context` row, change its example column to read `raises OptionKeyError — use :ssl` so the table does not advertise an unsupported option.

- [ ] **Step 3: Update CLAUDE.md Error Classes section**

In `CLAUDE.md`, find the `## Error Classes` section and replace its table with the unified hierarchy:

```markdown
All pool/registry errors descend from `HttpConnectionPool::Error`. Legacy
constants (`Pool::TimeoutError`, `Pool::ClosedError`, `Registry::PoolLimitError`)
are aliases of the canonical classes in `errors.rb`.

| Class                                  | When raised                                         |
| -------------------------------------- | --------------------------------------------------- |
| `HttpConnectionPool::TimeoutError`     | No connection available within `timeout`            |
| `HttpConnectionPool::ClosedError`      | `#with` called on a closed pool                     |
| `HttpConnectionPool::PoolLimitError`   | New pool would exceed `max_pools` cap               |
| `HttpConnectionPool::InvalidURLError`  | URL has no/unsupported scheme or no host (`ConfigurationError`) |
| `HttpConnectionPool::OptionKeyError`   | Option value not safely keyable (`ConfigurationError`) |

`Registry#pool_key` rejects any option value that is not a scalar or a
hash/array of scalars (`KEYABLE_SCALARS`), so `ssl_context:` raises
`OptionKeyError` — this prevents a silent collision where different credentials
map to the same SHA-256 key. Restoring `ssl_context:` support is deferred to the
canonical-serializer work (case C) in
`docs/superpowers/specs/2026-06-25-error-handling-design.md`.

Request-body `HTTP::*` errors propagate raw and are intentionally not remapped.

`max_pools must be >= 1` (`ArgumentError`) and the `Registry.configure`
already-initialised guard (`RuntimeError`) stay as core errors — they are
programmer-contract violations, not pool-domain errors.
```

If the existing section has the `Registry#stats` note above the table, preserve it.

- [ ] **Step 4: Run full CI**

Run: `bundle exec rake ci`
Expected: bundler-audit `No vulnerabilities found`; RuboCop no offenses; RSpec all examples pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "$(cat <<'EOF'
Document the error hierarchy and ssl_context OptionKeyError behaviour

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage (design doc → tasks):**
- Error hierarchy + aliases → Task 1.
- `InvalidURLError` from `extract_origin` → Task 2.
- `OptionKeyError` keyability guard (pool_for + release), message names key/class not value, collision regression → Task 3.
- `ssl_context:` regression in pool_spec → Task 4.
- Request-body pass-through (option B) → no code change needed (Pool#with already only translates checkout-level failures); documented in Task 5.
- Core errors stay core (`max_pools`, `configure`) → unchanged, documented in Task 5.
- README + CLAUDE.md → Task 5.
- Case C deferred → captured as a code comment (Task 3, `KEYABLE_SCALARS`) and CLAUDE.md note (Task 5), pointing at the design doc.
All design sections map to a task. No gaps.

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output.

**Type/name consistency:** `HttpConnectionPool::Error`, `ConfigurationError`, `InvalidURLError`, `OptionKeyError`, `PoolLimitError`, `TimeoutError`, `ClosedError`, `ensure_keyable!`, and `KEYABLE_SCALARS` are defined in Tasks 1/3 and referenced consistently. Aliases (`Pool::TimeoutError`, `Pool::ClosedError`, `Registry::PoolLimitError`) are asserted `.equal?` to the canonical classes in Task 1 and relied on in Tasks 2–4. The guard's safe-type list matches the spec's allowed-types list exactly.
