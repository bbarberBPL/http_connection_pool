# HttpConnectionPool

Thread-safe (and Fiber-scheduler-aware) persistent HTTP connection pooling for
the [http.rb](https://github.com/httprb/http) gem.

`HttpConnectionPool` keeps **one pool of persistent `HTTP::Session` connections
per URL origin** (scheme + host + port) and hands them out to threads or fibers
on demand. It is built on top of the battle-tested
[`connection_pool`](https://github.com/mperham/connection_pool) gem and uses
[`concurrent-ruby`](https://github.com/ruby-concurrency/concurrent-ruby)
primitives for its registry, so checkouts are safe under heavy concurrency
without you having to manage sockets, mutexes, or keep-alive state yourself.

On http.rb v6, `HTTP.persistent` returns an `HTTP::Session`, and http.rb's own
README notes that a persistent session is **not** thread-safe on its own —
it recommends pairing it with the `connection_pool` gem. That is exactly what
this gem does, with an origin-keyed registry, a `Connectable` mixin, and
credential-isolated pools layered on top.

## Features

- **Persistent connections** — reuses keep-alive `HTTP::Session` connections
  instead of opening a fresh socket per request.
- **One pool per origin** — a global registry guarantees a single shared pool
  for every `scheme://host:port`, normalised automatically from any URL.
- **Thread-safe & fiber-aware** — backed by `connection_pool`, so a blocking
  checkout yields to the fiber scheduler when one is active instead of parking
  the OS thread.
- **Bounded with timeouts** — configurable pool size and checkout timeout;
  exhausted pools raise `HttpConnectionPool::Pool::TimeoutError` rather than
  blocking forever.
- **`Connectable` mixin** — drop into any service/API client class (or `extend`
  onto a module) for a clean `with_connection { |conn| ... }` API.
- **Introspectable** — `#stats` exposes pool size, checked-out, and idle counts.

## Requirements

- Ruby `>= 3.3.0`. Tested on **MRI (CRuby)**. JRuby support is planned but
  currently **untested** — `http.rb` selects its parser by engine
  ([`llhttp`](https://rubygems.org/gems/llhttp), a native C extension, on MRI
  and `llhttp-ffi` on JRuby), so JRuby installs are not blocked, just not yet
  verified.
- On MRI, a C compiler/toolchain is needed at install time, since the `llhttp`
  extension is compiled during `gem install` / `bundle install`. On
  Debian/Ubuntu, for example, install `build-essential`; on macOS, the Xcode
  Command Line Tools.

### Dependency tree

This gem pulls in the following runtime dependencies:

| Gem               | Version constraint       | Notes                                  |
| ----------------- | ------------------------ | -------------------------------------- |
| `http`            | `~> 6.0`                 | The underlying http.rb client          |
| `connection_pool` | `>= 2.5.5, < 3`          | Generic, fiber-aware pooling primitive |
| `concurrent-ruby` | `>= 1.3.7, ~> 1.3`       | Lock-free registry & atomics; floor fixes CVE-2026-54904/54905/54906 |

`http.rb` in turn brings in `http-cookie`, `domain_name`, and its parser
(`llhttp` on MRI, `llhttp-ffi` on JRuby). All are pure Ruby except the native
`llhttp` build used on MRI.

## Installation

Add it to your application's Gemfile:

```ruby
gem 'http_connection_pool'
```

Then run:

```bash
bundle install
```

Or install it directly:

```bash
gem install http_connection_pool
```

## Usage

### The `Connectable` mixin (recommended)

Include `HttpConnectionPool::Connectable` in a client class and configure it
with a base URL. Each class sharing a base URL transparently shares one pool.

```ruby
require 'http_connection_pool'

class GithubClient
  include HttpConnectionPool::Connectable

  self.base_url     = 'https://api.github.com'
  self.pool_size    = 10
  self.pool_timeout = 3.0
  self.pool_options = { headers: { 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}" } }

  def user(login)
    with_connection { |conn| conn.get("/users/#{login}").parse }
  end
end

GithubClient.new.user('bbarberBPL')
```

You can also `extend` it onto a module for a class-method-only API:

```ruby
module GithubAPI
  extend HttpConnectionPool::Connectable

  self.base_url = 'https://api.github.com'

  def self.user(login)
    with_connection { |conn| conn.get("/users/#{login}").parse }
  end
end
```

### Using the registry directly

If you don't want the mixin, reach for the registry. It returns (and caches) a
pool for any URL's origin:

```ruby
registry = HttpConnectionPool::Registry.instance

registry.pool_for('https://api.example.com').with do |conn|
  conn.get('/status').parse
end
```

### Configuration options

`pool_options` (or the keyword args to `pool_for`) configure every
`HTTP::Session` in the pool:

| Option        | Applied via               | Example                                       |
| ------------- | ------------------------- | --------------------------------------------- |
| `:timeout`    | `HTTP::Session#timeout`   | `{ timeout: 5 }`                              |
| `:headers`    | `HTTP::Session#headers`   | `{ headers: { 'Accept' => 'application/json' } }` |
| `:auth`       | `HTTP::Session#auth`      | `{ auth: 'Bearer token' }`                    |
| `:proxy`      | `HTTP::Session#via`       | `{ proxy: ['proxy.example.com', 8080] }`      |
| `:ssl`        | session SSL options       | `{ ssl: { ... } }`                            |
| `:ssl_context`| session SSL options       | `{ ssl_context: OpenSSL::SSL::SSLContext.new }`|

> **Note (http.rb v6):** the chainable `.ssl` method was removed in http v6, so
> `:ssl` / `:ssl_context` are seeded into the session's options *before* it is
> made persistent rather than applied as a chainable call. The behaviour from a
> caller's perspective is unchanged.

### One pool per (origin + options), and credential isolation

Pools are keyed by a **SHA-256 digest of the origin and options**, so two
callers that target the same host but supply different credentials each get
their own isolated pool. There is no error, no interference, and no shared
connections:

```ruby
# Each token gets its own pool — no conflict.
registry.pool_for('https://api.example.com', headers: { 'Authorization' => 'Bearer aaa' })
registry.pool_for('https://api.example.com', headers: { 'Authorization' => 'Bearer bbb' })
```

Requesting the same origin with **identical** options returns the cached pool
without allocating a new one.

This design also makes subclassing safe. A subclass that overrides
`pool_options` receives its own isolated pool; a subclass that leaves
`pool_options` untouched shares the parent's pool:

```ruby
class BaseClient
  include HttpConnectionPool::Connectable
  self.base_url  = 'https://api.example.com'
  self.pool_size = 10
end

class AdminClient < BaseClient
  # Inherits base_url and pool_size; gets a separate pool for admin credentials.
  self.pool_options = { headers: { 'Authorization' => "Bearer #{ENV['ADMIN_TOKEN']}" } }
end

class ReadOnlyClient < BaseClient
  self.pool_options = { headers: { 'Authorization' => "Bearer #{ENV['READONLY_TOKEN']}" } }
end

# BaseClient, AdminClient, and ReadOnlyClient each have their own pool.
# BaseClient.connection_pool      — no auth
# AdminClient.connection_pool     — admin token, never mixed with read-only
# ReadOnlyClient.connection_pool  — read-only token, never mixed with admin
```

> **Note:** `pool_options` on a subclass *replaces* the parent's options
> entirely — it does not merge them. If you need to add headers on top of a
> parent's defaults, merge explicitly:
> ```ruby
> self.pool_options = BaseClient.pool_options.merge(
>   headers: BaseClient.pool_options.fetch(:headers, {}).merge(
>     'X-Extra' => 'value'
>   )
> )
> ```

**Option-hash key ordering** does not matter — `{ 'X-A' => '1', 'X-B' => '2' }`
and `{ 'X-B' => '2', 'X-A' => '1' }` are treated as the same options and
return the same pool. The registry normalises nested hashes before hashing.

When you `release` a pool you must pass the same options so the registry can
locate the correct key:

```ruby
registry.release('https://api.example.com', headers: { 'Authorization' => 'Bearer aaa' })
```

Credentials are kept out of `#inspect`, `#to_s`, and `pp` output for both the
pool and the registry:

```ruby
pool.inspect
# => #<HttpConnectionPool::Pool origin="https://api.github.com:443" size=10 \
#      timeout=3.0 closed=false options=[headers, auth]>

HttpConnectionPool::Registry.instance.inspect
# => #<HttpConnectionPool::Registry pools=3 max_pools=unlimited>
```

### Bounding the number of pools

By default the registry holds an unbounded number of pools — one per distinct
origin. If origins can be influenced by **untrusted input** (webhook targets,
redirect hosts, user-supplied URLs), cap the registry so a flood of unique
origins can't exhaust memory or file descriptors:

```ruby
# Per-registry:
registry = HttpConnectionPool::Registry.new(max_pools: 100)

# Or for the process-wide singleton, before first use (e.g. a Rails initializer):
HttpConnectionPool::Registry.configure(max_pools: 100)
```

Creating a pool for a *new* origin beyond the cap raises
`HttpConnectionPool::Registry::PoolLimitError`; reusing an existing origin is
never blocked, and `release`-ing a pool frees a slot. The cap is a soft limit —
under heavy concurrency the count may briefly overshoot by the number of
distinct origins racing to be created, but growth stays bounded.

### Inspecting pool state

```ruby
# Stats for a single pool:
pool = GithubClient.connection_pool
pool.stats
# => { origin: "https://api.github.com:443", size: 10,
#      checked_out: 0, idle: 10, closed: false }

# Stats for all pools in the registry (Array, one entry per pool):
HttpConnectionPool::Registry.instance.stats
# => [
#      { origin: "https://api.github.com:443", size: 10, ... },
#      { origin: "https://api.example.com:443", size: 5,  ... },
#    ]
```

### Shutting pools down

```ruby
GithubClient.release_connection_pool          # close one class's pool
HttpConnectionPool::Registry.instance.close_all  # close every pool
```

Prefer `release_connection_pool` / `Registry#release` / `close_all`, which both
close the pool **and** remove it from the registry. Calling `Pool#close`
directly on a pool you obtained from the registry closes its connections but
leaves the dead entry in the registry until its exact key is requested again —
the entry keeps its slot under [`max_pools`](#bounding-the-number-of-pools)
until then. A long-running process that closes pools out-of-band can reclaim
them all at once:

```ruby
HttpConnectionPool::Registry.instance.sweep_closed!  # evict closed pools, returns count
```


### Forking app servers (Puma, Unicorn, Spring, Resque, Sidekiq)

Clustered Puma, Unicorn, and other preforking servers boot the app **once in a
parent process** and then `fork` worker processes. A network socket must never
be shared across a fork — two processes reading and writing the same TLS/HTTP
connection will corrupt each other's streams.

**The good news:** this gem's backing `connection_pool` (>= 2.5) is fork-aware.
It defaults to `auto_reload_after_fork: true` and hooks `Process._fork`, so a
freshly forked worker automatically **discards any inherited connections and
opens its own** on first checkout. You do not need to do anything for
correctness — there is no risk of workers sharing a socket.

What is still worth doing is **hygiene**: proactively close inherited pools in
each worker so you start from a clean slate and don't briefly retain the
parent's (now-defunct) connection objects. Every server exposes an
`after_fork`/`on_worker_boot` hook for exactly this:

```ruby
# Puma — config/puma.rb
on_worker_boot do
  HttpConnectionPool::Registry.instance.close_all
end

# Unicorn — config/unicorn.rb
after_fork do |_server, _worker|
  HttpConnectionPool::Registry.instance.close_all
end
```

```ruby
# Resque
Resque.after_fork { HttpConnectionPool::Registry.instance.close_all }

# Sidekiq runs jobs in threads, not forks, so no per-job reset is needed; the
# shared pool is what you want there.
```

The parent process is unaffected by a worker closing its own copy — each forked
worker gets its own copy-on-write view of the singleton registry. You can pair
this with `Registry.configure(max_pools:)` (see above) in the parent's boot so
every worker inherits the same ceiling.

It is also good practice to close pools on graceful shutdown so connections are
released promptly rather than waiting on GC / socket timeouts:

```ruby
at_exit { HttpConnectionPool::Registry.instance.close_all }
```

## Security

Keeping a persistent connection open means any header configured on the pool
(`auth`, `Authorization`, `Cookie`) is reused for every request on that
connection. Two practices keep that from leaking:

- **Never build a request path from untrusted input without validating it.**
  A protocol-relative path (`//evil-host/path`) can be interpreted as a
  network-path reference that replaces the origin's authority, redirecting the
  request — and its connection-scoped credentials — to an attacker-controlled
  host. As a defensive measure, reject request paths that begin with `//`
  before passing them to `with_connection`.
- **Cap the registry when origins come from untrusted input** — see
  [Bounding the number of pools](#bounding-the-number-of-pools).

Credentials are also kept out of `#inspect`, `#to_s`, and `pp` output for both
the pool and the registry (origin, size, and option *keys* only — never option
values). See
[credential isolation](#one-pool-per-origin--options-and-credential-isolation).

## Rails compatibility

This gem works inside Rails (verified against the **7.2.x** series) but does
**not** depend on Rails — it stays usable in any plain-Ruby project. Rails and
this gem share two dependencies, and the version constraints overlap cleanly:

| Shared dep        | Rails 7.2 requires    | This gem requires  |
| ----------------- | --------------------- | ------------------ |
| `concurrent-ruby` | `~> 1.0, >= 1.3.1`    | `~> 1.3`           |
| `connection_pool` | `>= 2.2.5`            | `>= 2.5.5, < 3`    |

Compatibility is enforced in CI: `activesupport` is pulled into the **test
group only** (never the gemspec), and `spec/integration/rails_compatibility_spec.rb`
asserts the resolved dependency versions satisfy both Rails and this gem, and
that the `Connectable` mixin behaves correctly under a Rails-style service
object (including across class reloads). To test a newer Rails, bump the
`activesupport` pin in the Gemfile and re-run the suite.

### Zeitwerk

The gem loads its own constants with plain `require_relative`, so it is
invisible to — and safe for — a host Rails app's Zeitwerk loader, even under
`eager_load` in production. Its file/constant layout is nonetheless fully
Zeitwerk-conformant: `spec/integration/zeitwerk_compliance_spec.rb` eager-loads
the gem through a real `Zeitwerk::Loader` (in a clean process) and fails if any
file/constant naming ever drifts. Like every gem, only `version.rb` is exempt
(it defines `VERSION`, not `Version`). Zeitwerk is a **test-only** dependency,
never a runtime one.

### Background jobs

The gem is also verified inside background jobs:
`spec/integration/background_job_spec.rb` runs the `Connectable` pool through a
bare `Sidekiq::Job`, an Active Job on the `:test` adapter, and an Active Job on
the `:sidekiq` adapter (all under `Sidekiq::Testing.inline!`, no Redis). It
asserts that jobs hitting one origin share a single pool, that job classes with
different credentials get isolated pools, that a connection is returned to the
pool when a job raises, and that neither the registry nor the live `Pool` count
grows with job count. Sidekiq and Active Job are **test-only** dependencies.

## Development

After checking out the repo, install dependencies and run the test suite:

```bash
bin/setup          # bundle install
bundle exec rake   # runs RuboCop, then RSpec (the default `ci` task)
```

For an interactive sandbox with the gem and an `EXAMPLE` client preloaded:

```bash
bin/console
```

```ruby
>> EXAMPLE.with_connection { |conn| conn.get('/get').status }
>> EXAMPLE.connection_pool_stats
```

### Examples

The [`examples/`](examples/) directory has runnable, real-backend examples that
are not part of the gem package. [`examples/solr_client.rb`](examples/solr_client.rb)
is a `Connectable` client for a Solr 8.11.x core, and
[`examples/solr_update_demo.rb`](examples/solr_update_demo.rb) walks an
add/update/read/delete round-trip through the pool. See
[`examples/README.md`](examples/README.md) for how to run them.

### Building and publishing

```bash
bundle exec rake build            # build the gem into pkg/ (gitignored)
bundle exec rake build:checksum   # build, then write SHA-256 + SHA-512 to checksums/
```

`rake build:checksum` records both digests under `checksums/` in the standard
`sha256sum -c` / `sha512sum -c` format, so a published artifact can be verified
against this repository. The built `.gem` is never committed; only its
checksums are.

Publishing to RubyGems is a manual, maintainer-only step — this project
deliberately ships no automated push task. Regenerate the checksums whenever
the version changes, immediately before publishing.

## License

Released under the [MIT License](LICENSE).
