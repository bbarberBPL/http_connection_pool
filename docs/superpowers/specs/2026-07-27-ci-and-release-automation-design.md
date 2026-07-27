# CI and release automation — design

## Goal

Give `http_connection_pool` a GitHub Actions CI build (MRI Ruby only, for now)
and an automated, MFA-compliant RubyGems publishing flow with a local
version-bump helper. Also verify the gem against the newly published `http`
6.0.4 (already allowed by the `~> 6.0` constraint, so no gemspec change) and
enrich the gemspec metadata (`homepage`, `homepage_uri`, `source_code_uri`,
`rubygems_mfa_required`).

Publishing remains **user-initiated**: a human pushes a version tag. CI does the
`gem push` via OIDC — the maintainer never runs `gem push` locally, and no
long-lived API key is stored anywhere. This honours the CLAUDE.md rule that gem
publishing is a user-only, outward-facing action while still automating the
mechanics.

## Background — current state

- No `.github/` at all; CI is run manually via `bundle exec rake ci`.
- `Rakefile` already provides `ci` (offline `bundle:audit:check` → RuboCop →
  RSpec), `audit` (network-refreshing), `build`, and `build:checksum`.
- `Gemfile.lock` is gitignored — dependencies resolve fresh each run, so CI
  naturally picks up `http` 6.0.4 and any other in-range upgrade.
- `spec.required_ruby_version = '>= 3.3.0'`. Gem is MRI-tested; JRuby untested.
- The `llhttp` native extension compiles at install time; `ubuntu-latest` ships
  the C toolchain, so no extra apt step is needed.
- Version is `0.1.0`, not yet published to RubyGems.

## Decisions

1. **CI: two jobs, MRI only.**
   - `test` — matrix over Ruby `3.3` and `3.4` on `ubuntu-latest`, running
     `bundle exec rake ci`.
   - `security` — a single job running `bundle exec rake audit` (network refresh
     of the advisory DB, then check). Separated so an advisory failure is
     distinguishable from a test failure. `rake ci`'s own offline
     `bundle:audit:check` inside `test` no-ops without a cloned DB; the
     `security` job is the authoritative scan. This is noted in a workflow
     comment so the offline no-op is not mistaken for coverage.
   - No JRuby/TruffleRuby matrix (untested; the `max_pools` soft-cap spec asserts
     an exact rejection count that holds only under MRI's GVL — see CLAUDE.md).

2. **Version bump: local Rake tasks, no git operations.**
   `rake bump:patch` / `bump:minor` / `bump:major` rewrite `VERSION` in
   `lib/http_connection_pool/version.rb`, then invoke `build:checksum` to
   regenerate `checksums/` for the new version. The task edits files only — it
   never commits, tags, or pushes (those stay the maintainer's hands, mirroring
   the `git push` deny rule). It prints the exact follow-up git commands.

3. **Release: OIDC Trusted Publishing, tag-triggered.**
   Pushing a tag matching `v*.*.*` triggers `release.yml`, which verifies the
   tag matches `HttpConnectionPool::VERSION`, runs the suite, verifies checksums,
   and publishes via `rubygems/release-gem@v1` (the official Trusted Publishing
   action). No API-key secret is stored; CI mints a short-lived OIDC token.

4. **MFA: `rubygems_mfa_required = 'true'` in gemspec metadata.**
   This makes the gem demand MFA for privileged interactive operations (yank,
   ownership changes, manual pushes, key management) — guarded by the
   maintainer's authenticator app. OIDC Trusted Publishing is accepted by
   RubyGems as satisfying the MFA requirement (the verified GitHub Actions
   identity is the second factor), so it coexists with this metadata: a green
   tag push publishes automatically, with no TOTP prompt in CI. No per-release
   approval gate is added.

5. **Gemspec metadata enrichment.**
   Add `homepage`, `metadata['homepage_uri']`, `metadata['source_code_uri']`,
   and `metadata['rubygems_mfa_required']`.

## CI workflow — `.github/workflows/ci.yml`

Triggers: `push` to `main`, and `pull_request`.

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby: ['3.3', '3.4']
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      # rake ci runs bundle:audit:check OFFLINE (no DB cloned here, so it
      # no-ops) -> RuboCop -> RSpec. The authoritative CVE scan is the
      # `security` job below, which refreshes the advisory DB over the network.
      - run: bundle exec rake ci

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true
      - run: bundle exec rake audit
```

A CI status badge is added to the top of `README.md`.

## Version-bump Rake tasks — `bump` namespace in `Rakefile`

```ruby
namespace :bump do
  %i[major minor patch].each do |level|
    desc "Bump the #{level} version, then regenerate checksums"
    task(level) { bump_version(level) }
  end
end
```

`bump_version`:

1. Reads the current `VERSION` from `lib/http_connection_pool/version.rb`.
2. Splits `MAJOR.MINOR.PATCH`, increments the requested component (zeroing the
   lesser components), builds the new string.
3. Rewrites only the `VERSION = '...'` line via a targeted regex, preserving the
   `# frozen_string_literal: true` header and single-quote style.
4. Invokes `Rake::Task['build:checksum']` (with the version constant reloaded)
   so `checksums/` reflects the new version.
5. Prints the follow-up commands for the maintainer to run:
   ```
   git commit -am 'Release vX.Y.Z'
   git tag vX.Y.Z
   git push && git push --tags
   ```

The task performs no git operations itself.

## Release workflow — `.github/workflows/release.yml`

Triggers: `push` of a tag matching `v*.*.*`.

```yaml
name: Release
on:
  push:
    tags: ['v*.*.*']

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: write   # create the GitHub Release
      id-token: write   # OIDC token for Trusted Publishing
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true

      # Fail early if the pushed tag does not match version.rb.
      - name: Verify tag matches gem version
        run: |
          gem_version="$(ruby -Ilib -r http_connection_pool/version \
            -e 'print HttpConnectionPool::VERSION')"
          tag_version="${GITHUB_REF_NAME#v}"
          if [ "$gem_version" != "$tag_version" ]; then
            echo "Tag $GITHUB_REF_NAME does not match VERSION $gem_version" >&2
            exit 1
          fi

      - run: bundle exec rake spec
      - run: bundle exec rake rubocop

      # Rebuild checksums and fail if they differ from the committed ones,
      # so the published artifact matches what the repo attests.
      - name: Verify committed checksums
        run: |
          bundle exec rake build:checksum
          git diff --exit-code checksums/

      - uses: rubygems/release-gem@v1
```

The version guard and the checksum gate both run **before** publish, so a
mismatched tag or stale checksum fails without pushing anything to RubyGems.

## One-time maintainer setup (documented, not automatable by the assistant)

Before the first release, the maintainer registers this repo as a Trusted
Publisher on RubyGems (the assistant cannot — no rubygems.org access, and it is
the maintainer's account):

1. Sign in to rubygems.org (with the account that will own the gem).
2. For a gem that does not exist yet, add a **pending** trusted publisher under
   the profile's OIDC / Trusted Publishers settings; for an existing gem, use
   the gem's *Trusted Publishers* page.
3. Add a GitHub Actions publisher: repository `bbarberBPL/http_connection_pool`,
   workflow filename `release.yml` (environment left blank).

Until this registration exists, the `rubygems/release-gem@v1` step fails — this
is documented as a prerequisite in the README and CLAUDE.md.

## Verifying against http 6.0.4

`http` 6.0.4 was published 2026-07-14 and is already allowed by the gemspec's
`~> 6.0` constraint (confirmed via the RubyGems versions API). Verification is
`bundle update http` locally followed by a green `bundle exec rake ci`; no
gemspec edit is required. CI resolves fresh each run (lockfile is gitignored),
so it exercises 6.0.4 automatically.

## Documentation

Updated in the same change as the code (standing CLAUDE.md instruction):

- **README.md:** add a CI status badge; replace the "no automated push task"
  paragraph with the tag-triggered release flow (`rake bump:*` → commit → tag →
  push → CI publishes); note the Trusted Publisher one-time setup and the
  `rubygems_mfa_required` posture.
- **CLAUDE.md:** add a CI + release section; add `bump:*` to the Rake-tasks
  table; reaffirm that publishing stays tag-triggered and user-initiated (the
  assistant authors the workflow but never runs `gem push`/`git push`); record
  the gemspec metadata additions.

## Out of scope

- JRuby / TruffleRuby CI matrix (untested; would require relaxing the
  GVL-dependent `max_pools` spec — deferred).
- Per-release GitHub Environment approval gate (considered; declined in favour
  of the simpler MFA-metadata-only posture).
- release-please / conventional-commit automation (declined in favour of the
  explicit manual bump + tag flow).
- Automated `git commit`/`git tag`/`git push` from Rake (declined — git
  operations stay the maintainer's).
- Storing a RubyGems API key as a GitHub secret (declined in favour of OIDC).

## Verification

- `bundle exec rake ci` stays green locally with http 6.0.4 resolved.
- The `bump:*` tasks correctly increment each component, rewrite only the
  VERSION line, and regenerate `checksums/`.
- Workflow YAML is syntactically valid and the version guard / checksum gate
  logic is sound (verified by inspection; the publish step is only exercisable
  after the maintainer registers the Trusted Publisher).
