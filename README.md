# HttpConnectionPool

Thread-safe (and Fiber-scheduler-aware) persistent HTTP connection pooling for
the [http.rb](https://github.com/httprb/http) gem.

`HttpConnectionPool` keeps **one pool of persistent `HTTP::Client` connections
per URL origin** (scheme + host + port) and hands them out to threads or fibers
on demand. It is built on top of the battle-tested
[`connection_pool`](https://github.com/mperham/connection_pool) gem and uses
[`concurrent-ruby`](https://github.com/ruby-concurrency/concurrent-ruby)
primitives for its registry, so checkouts are safe under heavy concurrency
without you having to manage sockets, mutexes, or keep-alive state yourself.

## Features

- **Persistent connections** — reuses keep-alive `HTTP::Client` connections
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

- Ruby `>= 3.3.0`
- A C compiler/toolchain at install time. This gem depends on `http.rb`, whose
  transitive dependency [`llhttp`](https://rubygems.org/gems/llhttp) ships a
  native C extension that is compiled during `gem install` / `bundle install`.
  On Debian/Ubuntu, for example, install `build-essential`; on macOS, the Xcode
  Command Line Tools.

### Dependency tree

This gem pulls in the following runtime dependencies:

| Gem               | Version constraint  | Notes                                  |
| ----------------- | ------------------- | -------------------------------------- |
| `http`            | `~> 6.0`            | The underlying http.rb client          |
| `connection_pool` | `>= 2.5.5, < 3`     | Generic, fiber-aware pooling primitive |
| `concurrent-ruby` | `~> 1.3`            | Lock-free registry & atomics           |

`http.rb` in turn brings in `http-cookie`, `domain_name`, and `llhttp` (the
native parser noted above). All are pure Ruby except `llhttp`.

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

`pool_options` (or the keyword args to `pool_for`) are forwarded to every
`HTTP::Client` in the pool:

| Option        | Forwarded to            | Example                                       |
| ------------- | ----------------------- | --------------------------------------------- |
| `:timeout`    | `HTTP::Client#timeout`  | `{ timeout: 5 }`                              |
| `:headers`    | `HTTP::Client#headers`  | `{ headers: { 'Accept' => 'application/json' } }` |
| `:auth`       | `HTTP::Client#auth`     | `{ auth: 'Bearer token' }`                    |
| `:proxy`      | `HTTP::Client#via`      | `{ proxy: ['proxy.example.com', 8080] }`      |
| `:ssl`        | `HTTP::Client#ssl`      | `{ ssl: { ... } }`                            |
| `:ssl_context`| `HTTP::Client#ssl`      | `{ ssl_context: OpenSSL::SSL::SSLContext.new }`|

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

## License

Released under the [MIT License](LICENSE).
