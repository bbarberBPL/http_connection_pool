# Options Build Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `Pool#build_connection` to construct connections through a single `HTTP::Options` object (with `persistent` as a field), deep-freeze pool options, and give docs/examples a language pass — without reimplementing http.rb's private timeout/proxy translation.

**Architecture:** `build_connection` builds one `HTTP::Options` for the directly-mappable fields (headers+auth, ssl, persistent=origin), constructs an `HTTP::Session` from it, then applies only `timeout`/`proxy` via the chainable (which http.rb translates). `@options` is deep-frozen in the constructor. `ssl_context` is omitted from the built options with a TODO (it stays rejected at the registry keying boundary; case C deferred).

**Tech Stack:** Ruby (MRI), http.rb v6 (`HTTP::Options`, `HTTP::Session`), RSpec, RuboCop.

## Global Constraints

- MRI-tested; no new runtime dependency. Touches only `lib/http_connection_pool/pool.rb` (plus specs and docs).
- Every Ruby file begins with `# frozen_string_literal: true`. All non-interpolated strings use single quotes.
- No apostrophes inside RSpec `it`/`describe`/`context` strings (Ruby SyntaxError).
- `RSpec/MultipleExpectations: Max: 3`, `RSpec/ExampleLength: Max: 20`.
- `Metrics/MethodLength: Max: 20`, `Metrics/AbcSize` ~17. Keep methods short; extract private helpers rather than adding inline `# rubocop:disable`.
- `bundle exec rubocop` must be clean (`bundle exec rubocop -a` to auto-fix). `bundle exec rake ci` (bundler-audit → RuboCop → RSpec) must be green before any commit.
- **Git:** add files BY NAME, never `-A`/`.`. `Gemfile.lock` is gitignored — never stage it. Do NOT `git push` (user-only). End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Update README.md and CLAUDE.md in the same change as behaviour (standing instruction).
- `ssl_context:` is omitted from the built options with a `# TODO` pointing at `docs/superpowers/specs/2026-06-25-error-handling-design.md` (case C). It stays rejected at the registry keying boundary; do not wire it into the build.
- **SOLR PREREQUISITE (USER ACTION):** Any task that runs `examples/solr_update_demo.rb` against the live instance MUST pause and ask the user to start Solr (core `curator_development`, port 8983) first — do not assume it is up, do not silently skip live verification. A comment-only pass over the example files does NOT require Solr.

---

### Task 1: Refactor build_connection to an HTTP::Options-based path

**Files:**
- Modify: `lib/http_connection_pool/pool.rb` (replace `build_connection`/`persistent_session`/`ssl_options`/`apply_options` with the new build path)
- Test: `spec/http_connection_pool/pool_spec.rb` (extend the existing "building real connections (http v6 integration)" describe block)

**Interfaces:**
- Consumes: `@origin` (String), `@options` (Hash) — already set in `initialize`.
- Produces: `build_connection` returns a persistent `HTTP::Session` configured from `@options`. Private helpers: `native_options` (Hash for `HTTP::Options.new`), `headers_with_auth` (Hash), `apply_chainable(session)` (HTTP::Session).

- [ ] **Step 1: Write the failing tests**

In `spec/http_connection_pool/pool_spec.rb`, inside the existing `describe 'building real connections (http v6 integration)' do` block (which already has the `build(**options)` helper and un-stubs `HTTP.persistent` in a `before`), add these examples:

```ruby
    it 'sets persistent to the origin as an options field' do
      conn = build
      expect(conn.default_options.persistent).to eq('https://api.example.com')
    end

    it 'folds auth into an Authorization header' do
      conn = build(auth: 'Bearer xyz')
      expect(conn.default_options.headers['Authorization']).to eq('Bearer xyz')
    end

    it 'merges auth with explicit headers rather than clobbering them' do
      conn = build(auth: 'Bearer xyz', headers: { 'Accept' => 'application/json' })
      expect(conn.default_options.headers['Accept']).to eq('application/json')
      expect(conn.default_options.headers['Authorization']).to eq('Bearer xyz')
    end

    it 'applies a proxy option without error' do
      conn = build(proxy: ['proxy.example.com', 8080])
      expect(conn).to be_a(HTTP::Session)
    end
```

Note: `build`'s origin is `let(:origin) { 'https://api.example.com:443' }`; `HTTP::Options#persistent=` normalizes that to the origin `'https://api.example.com'` (no explicit default port in the stored value), which is why the expectation drops `:443`. If the running http version stores it differently, align the expected string to what `conn.default_options.persistent` actually returns (it is deterministic, not a socket call).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb -e 'building real connections'`
Expected: the new examples FAIL — the current `apply_options` chains `.headers`/`.auth` (so auth/headers may pass) but persistent is currently set via `.persistent(@origin)` chaining and the `default_options.persistent` value should still be present; the most likely first failures are the auth-merge and persistent-field examples. If an example unexpectedly passes, confirm it is asserting the NEW behaviour (persistent as a field, auth merged) and not coincidentally green; do not proceed until at least one new example is RED for the right reason.

- [ ] **Step 3: Replace the build path**

In `lib/http_connection_pool/pool.rb`, replace the entire private section from `def build_connection` through the end of `apply_options` (the current `build_connection`, `persistent_session`, `ssl_options`, and `apply_options` methods) with:

```ruby
    def build_connection
      session = HTTP::Session.new(HTTP::Options.new(**native_options))
      apply_chainable(session)
    end

    # Directly-mappable HTTP::Options fields, including persistent (= origin).
    # auth is folded into headers as an Authorization header, matching what
    # http.rb's own `auth` chainable does internally.
    def native_options
      opts = { persistent: @origin, headers: headers_with_auth }
      opts[:ssl] = @options[:ssl] if @options[:ssl]
      # TODO (case C): when ssl_context becomes safely keyable, set
      # opts[:ssl_context] = @options[:ssl_context] here. It is currently
      # rejected at the registry keying boundary, so it never reaches this
      # method. See docs/superpowers/specs/2026-06-25-error-handling-design.md.
      opts
    end

    # Merge auth into the headers hash as an Authorization header. Uses merge
    # (not mutation) so the frozen @options[:headers] is never modified.
    def headers_with_auth
      headers = @options[:headers] || {}
      return headers unless @options[:auth]

      headers.merge('Authorization' => @options[:auth])
    end

    # timeout/proxy need http.rb's own translation (number/hash -> timeout_class
    # + timeout_options; positional args -> proxy_hash), so they stay chainable.
    # Early-return when neither is set (the common case) to avoid extra
    # HTTP::Session allocations from branch/dup.
    def apply_chainable(session)
      return session unless @options[:timeout] || @options[:proxy]

      session = session.timeout(@options[:timeout]) if @options[:timeout]
      session = session.via(*@options[:proxy])      if @options[:proxy]
      session
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb`
Expected: PASS — all examples in the file, including the new ones and the retained `ssl:` hash example and the registry-boundary `ssl_context` rejection example.

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `bundle exec rspec`
Expected: all examples pass, 0 failures. (The build path is exercised by connectable_spec, registry_spec, fiber/thread specs via the stubbed `HTTP.persistent`, plus the un-stubbed pool_spec block.)

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop lib/http_connection_pool/pool.rb spec/http_connection_pool/pool_spec.rb`
Expected: no offenses. If `Metrics/AbcSize`/`MethodLength` flags anything, the methods above are small by design — extract a helper rather than disabling.

- [ ] **Step 7: Commit**

```bash
git add lib/http_connection_pool/pool.rb spec/http_connection_pool/pool_spec.rb
git commit -m "$(cat <<'EOF'
Build connections via a single HTTP::Options instead of chaining

persistent is set as an Options field; headers/auth/ssl go through
HTTP::Options.new; only timeout/proxy stay on the chainable (http.rb translates
them), with an early return when neither is set. ssl_context is omitted with a
case-C TODO and remains rejected at the registry keying boundary.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Deep-freeze pool options

**Files:**
- Modify: `lib/http_connection_pool/pool.rb` (`initialize` + new private `deep_freeze`)
- Test: `spec/http_connection_pool/pool_spec.rb`

**Interfaces:**
- Consumes: `options` kwargs in `initialize`.
- Produces: `@options` is a deeply-frozen Hash (nested hashes, arrays, and string values frozen). Private helper `deep_freeze(obj)` returns `obj` after freezing it and its descendants.

- [ ] **Step 1: Write the failing tests**

In `spec/http_connection_pool/pool_spec.rb`, add a new describe block (place it after the `#initialize` block):

```ruby
  describe 'option immutability' do
    subject(:pool) do
      described_class.new(origin: origin, size: 1, timeout: 1.0,
                          headers: { 'Accept' => 'application/json' },
                          ssl: { ciphers: %w[a b] })
    end

    after { pool.close }

    it 'freezes the options hash' do
      expect(pool.instance_variable_get(:@options)).to be_frozen
    end

    it 'freezes nested option hashes' do
      headers = pool.instance_variable_get(:@options)[:headers]
      expect(headers).to be_frozen
    end

    it 'freezes nested option arrays' do
      ciphers = pool.instance_variable_get(:@options)[:ssl][:ciphers]
      expect(ciphers).to be_frozen
    end

    it 'raises when a caller tries to mutate a nested option hash" \
       " after pool creation' do
      headers = pool.instance_variable_get(:@options)[:headers]
      expect { headers['X'] = '1' }.to raise_error(FrozenError)
    end
  end
```

(The fourth example's description is split across two string literals to avoid an apostrophe; keep it as written or rephrase without an apostrophe.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb -e 'option immutability'`
Expected: FAIL — the current `@options = options.freeze` is shallow, so the nested `headers` hash and `ssl[:ciphers]` array are NOT frozen; the nested-freeze and mutation examples fail.

- [ ] **Step 3: Add deep_freeze and use it in initialize**

In `lib/http_connection_pool/pool.rb`, change the assignment in `initialize` from:

```ruby
      @options = options.freeze
```

to:

```ruby
      @options = deep_freeze(options)
```

Then add this private method (place it in the private section, e.g. just above `build_connection`):

```ruby
    # Freeze the options hash and every nested hash/array/value, so a pool's
    # configuration cannot mutate after creation (and cannot diverge from the
    # options that were hashed into its registry key).
    def deep_freeze(obj)
      case obj
      when Hash  then obj.each { |k, v| deep_freeze(k); deep_freeze(v) }
      when Array then obj.each { |v| deep_freeze(v) }
      end
      obj.freeze
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb -e 'option immutability'`
Expected: PASS (4 examples).

- [ ] **Step 5: Run the full pool spec to confirm no regression**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb`
Expected: all pass. In particular the Task 1 build examples must still pass — `headers_with_auth` uses `merge` (not mutation), so a frozen `@options[:headers]` is fine.

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop lib/http_connection_pool/pool.rb spec/http_connection_pool/pool_spec.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add lib/http_connection_pool/pool.rb spec/http_connection_pool/pool_spec.rb
git commit -m "$(cat <<'EOF'
Deep-freeze pool options including nested hashes and arrays

Replaces the shallow @options.freeze so a pool's configuration (and the data
hashed into its registry key) cannot mutate after creation.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Verify relative-path resolution against the persistent origin

**Files:**
- Test: `spec/http_connection_pool/pool_spec.rb`

**Interfaces:**
- Consumes: the built session from Task 1 (`build`), plus `HTTP::Request::Builder` and `HTTP::Options` from http.rb.
- Produces: nothing for later tasks (a verification spec only).

- [ ] **Step 1: Write the test**

In `spec/http_connection_pool/pool_spec.rb`, inside the `describe 'building real connections (http v6 integration)' do` block, add:

```ruby
    it 'resolves a relative request path against the persistent origin' do
      conn = build
      request = HTTP::Request::Builder.new(conn.default_options).build(:get, '/users/1')
      expect(request.uri.to_s).to eq('https://api.example.com/users/1')
    end
```

This is deterministic and offline — `HTTP::Request::Builder` joins the relative path to the session's origin without opening a socket.

- [ ] **Step 2: Run the test**

Run: `bundle exec rspec spec/http_connection_pool/pool_spec.rb -e 'resolves a relative request path'`
Expected: PASS. (Controller verified this resolves to `https://api.example.com/users/1` offline.) If the built URI differs, align the expected string to the actual `request.uri.to_s` — but it must show the origin host and the `/users/1` path joined, proving relative paths resolve against the origin.

- [ ] **Step 3: RuboCop**

Run: `bundle exec rubocop spec/http_connection_pool/pool_spec.rb`
Expected: no offenses.

- [ ] **Step 4: Commit**

```bash
git add spec/http_connection_pool/pool_spec.rb
git commit -m "$(cat <<'EOF'
Verify relative request paths resolve against the persistent origin

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Documentation language pass (README, CLAUDE.md, case-C design doc)

**Files:**
- Modify: `README.md` (configuration-options section; relative-path note)
- Modify: `CLAUDE.md` (build-path + deep-freeze notes)
- Modify: `docs/superpowers/specs/2026-06-25-error-handling-design.md` (case C — living design doc)

**Interfaces:**
- Consumes: the behaviour shipped in Tasks 1-2.
- Produces: living docs matching the new build path.

- [ ] **Step 1: Update the README configuration-options section**

In `README.md`, find the `### Configuration options` section. Replace the introductory sentence and the table so it reflects that options are set on `HTTP::Options` at build time (not "forwarded via `HTTP::Session#timeout`"). Use this content (keep the existing v6 SSL note block that follows the table, but update its wording per Step 2):

```markdown
`pool_options` (or the keyword args to `pool_for`) configure every
`HTTP::Session` in the pool. Most are set on the underlying `HTTP::Options`
when the session is built; `timeout` and `proxy` use http.rb's chainable
translation:

| Option        | How it is applied                          | Example                                       |
| ------------- | ------------------------------------------ | --------------------------------------------- |
| `:headers`    | `HTTP::Options` `headers` field            | `{ headers: { 'Accept' => 'application/json' } }` |
| `:auth`       | folded into an `Authorization` header      | `{ auth: 'Bearer token' }`                    |
| `:ssl`        | `HTTP::Options` `ssl` field                | `{ ssl: { ca_file: '/path/ca.pem' } }`        |
| `:timeout`    | `HTTP::Session#timeout` (chainable)        | `{ timeout: 5 }`                              |
| `:proxy`      | `HTTP::Session#via` (chainable)            | `{ proxy: ['proxy.example.com', 8080] }`      |
| `:ssl_context`| not supported — raises `OptionKeyError`    | use `:ssl` instead                            |

Request paths are resolved against `base_url`'s origin, so pass relative paths
(`conn.get('/users/1')`) — they target the pool's `scheme://host:port`.
```

- [ ] **Step 2: Refresh the v6 SSL note wording**

In `README.md`, immediately after that table, replace the existing `> **Note (http.rb v6):**` block with:

```markdown
> **Note (http.rb v6):** `:ssl_context` is not supported. An `OpenSSL::SSL::SSLContext`
> cannot be safely used as a pool key — two contexts that differ only in a
> write-only field (e.g. `min_version`/`max_version`, which OpenSSL does not let
> us read back) would key to the same pool and silently share connections. So
> passing `:ssl_context` raises `HttpConnectionPool::OptionKeyError`. Configure
> TLS via the `:ssl` hash (`ssl: { ca_file: ..., verify_mode: ... }`) instead.
```

- [ ] **Step 3: Update CLAUDE.md**

In `CLAUDE.md`, find the Security/keying bullet list under design principle #2 (the `pool_key`/`extract_origin` bullets added previously). Add one bullet after them:

```markdown
- `Pool#build_connection` builds connections through a single `HTTP::Options`
  (headers+auth, ssl, `persistent: origin`) then `HTTP::Session.new`, applying
  only `timeout`/`proxy` via the chainable (http.rb translates those). Pool
  options are **deep-frozen** in `Pool#initialize` so a pool's configuration
  cannot mutate after creation.
```

- [ ] **Step 4: Update the case-C section of the error-handling design doc**

In `docs/superpowers/specs/2026-06-25-error-handling-design.md`, find the "Future work (case C ...)" section and replace it with:

```markdown
## Future work (case C — not in this plan)

Restoring keyable `ssl_context:` requires deriving a stable, collision-free
digest for an `OpenSSL::SSL::SSLContext`. An empirical probe showed this cannot
be done from the context's readable state: `min_version`/`max_version` are
write-only (raise `NoMethodError` on read), and raw OpenSSL-level options set in
C are not introspectable. Any digest built from readable fields would therefore
treat two genuinely different contexts as identical — reintroducing the silent
collision this guard exists to prevent.

Two viable routes when this is revisited:

1. **Caller-supplied key discriminator** — accept `ssl_context:` for building
   but require an accompanying caller-controlled key string that goes into the
   digest in place of the un-fingerprintable object. The caller asserts which
   contexts differ.
2. **Construction wrapping** — wrap `SSLContext` creation so the gem records the
   security-relevant material the caller set, and digest that recorded input.

Until then, `ssl_context:` is rejected by the keyability guard, and
`Pool#native_options` omits it (with a TODO pointing here). The build path
itself already accepts it via `HTTP::Options`, so only the keying side blocks it.
```

- [ ] **Step 5: Run full CI**

Run: `bundle exec rake ci`
Expected: bundler-audit clean; RuboCop no offenses; RSpec all examples pass, 0 failures. (Docs-only changes, but confirm nothing regressed.)

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md docs/superpowers/specs/2026-06-25-error-handling-design.md
git commit -m "$(cat <<'EOF'
Document HTTP::Options build path, deep-frozen options, and case-C findings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Example files language pass and live Solr verification

**Files:**
- Modify: `examples/solr_client.rb` (comment/language pass)
- Modify: `examples/solr_update_demo.rb` (comment/language pass, if needed)

**Interfaces:**
- Consumes: the shipped build path (Tasks 1-2). No code-behaviour change to the examples — they already use `headers` via `pool_options` and relative paths.
- Produces: example comments that match the new build-path vocabulary.

- [ ] **Step 1: Review the example files for stale build-path language**

Read `examples/solr_client.rb` and `examples/solr_update_demo.rb`. Look for any comment that describes options being "forwarded"/"chained" onto an `HTTP::Client`, or any `HTTP::Client` reference, or wording implying the old per-call chained-options behaviour. The client uses `self.pool_options = { headers: { 'Content-Type' => 'application/json' } }` and relative paths like `/solr/#{core}/...`, which are unchanged.

- [ ] **Step 2: Update only inaccurate comments**

Make minimal comment edits so the language matches reality: options are configured on the pooled `HTTP::Session` (via `pool_options`), requests use paths relative to the origin. Do NOT change the example's behaviour or method bodies. Ensure `# frozen_string_literal: true` and single-quoted strings are preserved. If a file's comments are already accurate, leave it unchanged and note that in the report.

- [ ] **Step 3: RuboCop the examples**

Run: `bundle exec rubocop examples/`
Expected: no offenses.

- [ ] **Step 4: PAUSE — ask the user to start Solr**

Before running the live demo, STOP and ask the user to start the local Solr instance (core `curator_development`, port 8983). Do not assume it is running. Wait for confirmation. If the user declines or cannot start it, skip Step 5 and record in the report that live verification was not run (do not mark it as passed).

- [ ] **Step 5: Run the live Solr demo (only after user confirms Solr is up)**

Run: `bundle exec ruby examples/solr_update_demo.rb`
Expected: output ends with `Done. Real data untouched.` and the final document count equals the starting count. This confirms the refactored build path works end-to-end against a real server (POST/update/read/delete round-trip, pool reuse).

- [ ] **Step 6: Commit**

```bash
git add examples/solr_client.rb examples/solr_update_demo.rb
git commit -m "$(cat <<'EOF'
Refresh Solr example comments for the HTTP::Options build path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

(If only one example file changed, stage only that file by name. If neither needed changes, skip the commit and note it in the report.)

---

## Self-Review

**Spec coverage (design doc → tasks):**
- Build via one `HTTP::Options`, persistent as a field, auth folded into headers, chainable timeout/proxy with early return → Task 1.
- `ssl_context` omitted with TODO, stays keying-rejected → Task 1 (`native_options` TODO).
- Deep-freeze `@options` (nested hashes/arrays) → Task 2.
- Relative-path resolution verification (base_uri option A) → Task 3.
- README options reframe + v6 SSL note + relative-path note → Task 4.
- case-C design doc update (write-only TLS fields, two routes) → Task 4.
- CLAUDE.md build-path + deep-freeze note → Task 4.
- Examples language pass → Task 5.
- Solr prerequisite (user must start Solr) → Task 5 Steps 4-5 (explicit pause), and Global Constraints.
All design sections map to a task. No gaps.

**Placeholder scan:** No TBD/TODO-as-work-deferral in steps (the one `# TODO` is intentional shipped code documenting case C). Every code step shows full code; commands have expected output.

**Type/name consistency:** `build_connection`, `native_options`, `headers_with_auth`, `apply_chainable`, `deep_freeze` are defined in Tasks 1-2 and referenced consistently. `native_options` returns a Hash consumed by `HTTP::Options.new(**...)`; `apply_chainable` takes and returns an `HTTP::Session`. The persistent-value expectation (`'https://api.example.com'`, no `:443`) is noted in Task 1 Step 1 with a fallback instruction. The deep-freeze test reads `@options` via `instance_variable_get`, matching the `@options = deep_freeze(options)` assignment.
