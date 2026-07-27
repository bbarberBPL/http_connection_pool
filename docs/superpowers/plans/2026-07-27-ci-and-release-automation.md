# CI and Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add MRI-only GitHub Actions CI, local version-bump Rake tasks, and a tag-triggered OIDC Trusted Publishing release workflow for the `http_connection_pool` gem, with enriched gemspec metadata and MFA.

**Architecture:** Two CI jobs (a `3.3`/`3.4` test matrix running `rake ci`, plus a separate network-audit job running `rake audit`). A pure `VersionBumper` module (in `tasks/`, not packaged) drives `rake bump:{patch,minor,major}` tasks that rewrite `version.rb` and regenerate checksums but perform no git operations. A `release.yml` workflow triggers on `v*.*.*` tags, guards tag-vs-version and checksum integrity, re-runs specs, then publishes via `rubygems/release-gem@v1` over OIDC. MFA is asserted via `rubygems_mfa_required` gemspec metadata.

**Tech Stack:** Ruby (MRI 3.3/3.4), Bundler, Rake, RSpec, RuboCop, GitHub Actions, `ruby/setup-ruby`, `rubygems/release-gem`, RubyGems Trusted Publishing (OIDC).

## Global Constraints

- All non-interpolated strings use single quotes.
- Every Ruby file begins with `# frozen_string_literal: true`.
- `bundle exec rubocop` and `bundle exec rake ci` must be clean before any commit.
- Never stage `Gemfile.lock` (gitignored); add files by name, never `-A`/`.`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- The assistant never runs `gem push`, `gem release`, `rake release`, or `git push` — those stay user-only. Authoring the workflow that does the push is allowed; running it is not.
- MRI only. No JRuby/TruffleRuby matrix (the `max_pools` soft-cap spec asserts an exact count that holds only under MRI's GVL).
- `spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md']` — files under `tasks/` are deliberately NOT packaged.
- CI runner: `ubuntu-latest` (ships the C toolchain `llhttp` needs).
- Target Ruby versions in CI matrix: exactly `'3.3'` and `'3.4'`.
- RubyGems metadata values (verbatim):
  - homepage: `https://rubygems.org/gems/http_connection_pool`
  - `source_code_uri`: `https://github.com/bbarberBPL/http_connection_pool`
- GitHub repo: `bbarberBPL/http_connection_pool`.

---

### Task 1: Gemspec metadata + verify http 6.0.4

**Files:**
- Modify: `http_connection_pool.gemspec`
- Create: `spec/gemspec_spec.rb`
- Modify: `.rubocop.yml` (add `spec/gemspec_spec.rb` to `RSpec/DescribeClass` Exclude)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a loadable gemspec whose `.metadata` contains `'homepage_uri'`, `'source_code_uri'`, `'rubygems_mfa_required'`, and whose `.homepage` is set. Later tasks (README/CLAUDE docs) reference these values.

- [ ] **Step 1: Write the failing test**

Create `spec/gemspec_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rubygems'

RSpec.describe 'http_connection_pool.gemspec' do
  subject(:spec) do
    Gem::Specification.load(File.expand_path('../http_connection_pool.gemspec', __dir__))
  end

  it 'sets the RubyGems homepage' do
    expect(spec.homepage).to eq('https://rubygems.org/gems/http_connection_pool')
  end

  it 'mirrors the homepage into metadata' do
    expect(spec.metadata['homepage_uri']).to eq('https://rubygems.org/gems/http_connection_pool')
  end

  it 'points source_code_uri at the GitHub repo' do
    expect(spec.metadata['source_code_uri'])
      .to eq('https://github.com/bbarberBPL/http_connection_pool')
  end

  it 'requires MFA for privileged operations' do
    expect(spec.metadata['rubygems_mfa_required']).to eq('true')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/gemspec_spec.rb`
Expected: FAIL — `homepage` is nil / metadata keys absent.

- [ ] **Step 3: Add the metadata to the gemspec**

In `http_connection_pool.gemspec`, immediately after the `spec.license = 'MIT'` line, add:

```ruby
  spec.homepage = 'https://rubygems.org/gems/http_connection_pool'
  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/bbarberBPL/http_connection_pool'
  spec.metadata['rubygems_mfa_required'] = 'true'
```

- [ ] **Step 4: Exclude the new spec from RSpec/DescribeClass**

The spec uses a string description (it describes the gemspec file, not a class). In `.rubocop.yml`, under `RSpec/DescribeClass:` → `Exclude:`, add:

```yaml
    - "spec/gemspec_spec.rb"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/gemspec_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 6: Verify against http 6.0.4**

Run:
```bash
bundle update http
bundle exec ruby -e 'require "http"; puts HTTP::VERSION'
bundle exec rake ci
```
Expected: resolved `http` is `6.0.4`; `rake ci` is green (bundler-audit offline → RuboCop → RSpec, all pass). No gemspec change needed — `~> 6.0` already allows 6.0.4.

- [ ] **Step 7: Commit**

```bash
git add http_connection_pool.gemspec spec/gemspec_spec.rb .rubocop.yml
git commit -m "Add gemspec homepage/source/MFA metadata; verify http 6.0.4

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Version-bump Rake tasks

**Files:**
- Create: `tasks/version_bumper.rb`
- Create: `spec/version_bumper_spec.rb`
- Modify: `Rakefile` (require the helper; add `bump` namespace)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `VersionBumper.next(current, level)` — takes a version String (`'0.1.0'`) and a level (`:major`/`:minor`/`:patch`, Symbol or String), returns the bumped version String. Zeroes all lesser components. Raises `ArgumentError` on an unknown level or a non-`MAJOR.MINOR.PATCH` input. Rake tasks `bump:major`, `bump:minor`, `bump:patch` rewrite `lib/http_connection_pool/version.rb` and regenerate checksums.

- [ ] **Step 1: Write the failing test**

Create `spec/version_bumper_spec.rb`:

```ruby
# frozen_string_literal: true

require_relative '../tasks/version_bumper'

RSpec.describe VersionBumper do
  describe '.next' do
    it 'bumps the patch component' do
      expect(described_class.next('0.1.0', :patch)).to eq('0.1.1')
    end

    it 'bumps the minor component and zeroes patch' do
      expect(described_class.next('0.1.4', :minor)).to eq('0.2.0')
    end

    it 'bumps the major component and zeroes minor and patch' do
      expect(described_class.next('1.4.9', :major)).to eq('2.0.0')
    end

    it 'accepts the level as a string' do
      expect(described_class.next('0.1.0', 'minor')).to eq('0.2.0')
    end

    it 'raises on an unknown level' do
      expect { described_class.next('0.1.0', :bogus) }.to raise_error(ArgumentError, /level/)
    end

    it 'raises on a malformed version' do
      expect { described_class.next('0.1', :patch) }.to raise_error(ArgumentError, /version/)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/version_bumper_spec.rb`
Expected: FAIL — cannot load `../tasks/version_bumper` (file does not exist).

- [ ] **Step 3: Write the pure helper**

Create `tasks/version_bumper.rb`:

```ruby
# frozen_string_literal: true

# Pure semantic-version arithmetic for the `bump:*` Rake tasks. Kept out of
# lib/ so it is never packaged into the gem (spec.files globs lib/**/*.rb only).
module VersionBumper
  LEVELS = %i[major minor patch].freeze

  def self.next(current, level)
    level = level.to_sym
    raise ArgumentError, "unknown level #{level.inspect}, expected one of #{LEVELS.inspect}" \
      unless LEVELS.include?(level)

    parts = current.split('.')
    raise ArgumentError, "malformed version #{current.inspect}, expected MAJOR.MINOR.PATCH" \
      unless parts.length == 3 && parts.all? { |p| p.match?(/\A\d+\z/) }

    major, minor, patch = parts.map(&:to_i)
    case level
    when :major then "#{major + 1}.0.0"
    when :minor then "#{major}.#{minor + 1}.0"
    when :patch then "#{major}.#{minor}.#{patch + 1}"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/version_bumper_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 5: Wire the Rake tasks**

In `Rakefile`, add near the top after the existing `require` lines:

```ruby
require_relative 'tasks/version_bumper'
```

Then add a new `bump` namespace (place it after the `namespace :build do ... end` block):

```ruby
VERSION_FILE = 'lib/http_connection_pool/version.rb'

namespace :bump do
  VersionBumper::LEVELS.each do |level|
    desc "Bump the #{level} version, regenerate checksums, and print the release commands"
    task(level) { bump_version(level) }
  end
end

def bump_version(level)
  contents = File.read(VERSION_FILE)
  current  = contents[/VERSION = '([^']+)'/, 1]
  raise "could not find VERSION in #{VERSION_FILE}" unless current

  bumped = VersionBumper.next(current, level)
  File.write(VERSION_FILE, contents.sub(/VERSION = '[^']+'/, "VERSION = '#{bumped}'"))
  puts "Bumped #{current} -> #{bumped}"

  # Run in a subprocess so the freshly written version.rb is loaded (this
  # process already required the old constant, which is frozen for its lifetime).
  sh 'bundle exec rake build:checksum'

  puts <<~NEXT
    Next steps (run these yourself):
      git add #{VERSION_FILE} checksums/
      git commit -m 'Release v#{bumped}'
      git tag v#{bumped}
      git push && git push --tags
  NEXT
end
```

- [ ] **Step 6: Verify RuboCop and the bump task behaviour**

Run: `bundle exec rubocop tasks/version_bumper.rb spec/version_bumper_spec.rb Rakefile`
Expected: no offenses.

Then dry-check the task end-to-end WITHOUT keeping the change — confirm it rewrites the line and regenerates checksums, then restore:
```bash
bundle exec rake bump:patch
git diff --stat            # should show version.rb changed + new checksums/ files
git checkout -- lib/http_connection_pool/version.rb   # restore 0.1.0
```
Then remove any `checksums/http_connection_pool-0.1.1.*` files the dry run created (leave the committed `0.1.0` checksums intact):
```bash
git status --porcelain checksums/
git clean -f checksums/    # removes only the untracked 0.1.1 checksum files
```
Expected: after restore, `git status` shows only the tracked source changes from Steps 3/5, and `version.rb` is back to `0.1.0`.

- [ ] **Step 7: Commit**

```bash
git add tasks/version_bumper.rb spec/version_bumper_spec.rb Rakefile
git commit -m "Add rake bump:{major,minor,patch} version tasks

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `rake ci` and `rake audit` (existing Rake tasks).
- Produces: a `CI` workflow with jobs named `test` (matrix) and `security`. Task 5's README badge links to this workflow file.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

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
      # `rake ci` runs bundle:audit:check OFFLINE. No advisory DB is cloned in
      # this job, so that step no-ops; the authoritative CVE scan is the
      # `security` job below, which refreshes the DB over the network.
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

- [ ] **Step 2: Validate the YAML parses**

Run: `bundle exec ruby -ryaml -e 'YAML.safe_load_file(".github/workflows/ci.yml"); puts "ok"'`
Expected: `ok` (no parse error).

- [ ] **Step 3: Verify the workflow shape**

Run:
```bash
bundle exec ruby -ryaml -e '
  w = YAML.safe_load_file(".github/workflows/ci.yml")
  raise "missing test job"     unless w["jobs"].key?("test")
  raise "missing security job" unless w["jobs"].key?("security")
  raise "wrong matrix" unless w.dig("jobs","test","strategy","matrix","ruby") == ["3.3","3.4"]
  puts "shape ok"
'
```
Expected: `shape ok`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add GitHub Actions CI (MRI 3.3/3.4 matrix + audit job)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `rake spec`, `rake build:checksum` (existing); the committed `checksums/` files; `HttpConnectionPool::VERSION`.
- Produces: a `Release` workflow triggered on `v*.*.*` tags that publishes via OIDC. No later task depends on it.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release.yml`:

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
      id-token: write   # OIDC token for RubyGems Trusted Publishing
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true

      - name: Verify tag matches gem version
        run: |
          gem_version="$(ruby -Ilib -r http_connection_pool/version \
            -e 'print HttpConnectionPool::VERSION')"
          tag_version="${GITHUB_REF_NAME#v}"
          if [ "$gem_version" != "$tag_version" ]; then
            echo "Tag $GITHUB_REF_NAME does not match VERSION $gem_version" >&2
            exit 1
          fi

      # Re-run the specs (not RuboCop) before publishing. A tag push does not
      # trigger ci.yml, and dependencies resolve fresh (Gemfile.lock is
      # gitignored), so this guards against a broken artifact under a newer
      # in-range dependency the last main CI run never saw. A yanked version
      # number can never be reused, so publishing red is uniquely costly.
      - run: bundle exec rake spec

      # Rebuild the checksums and fail if they differ from the committed ones,
      # so the published artifact matches what the repo attests.
      - name: Verify committed checksums
        run: |
          bundle exec rake build:checksum
          git diff --exit-code checksums/

      - uses: rubygems/release-gem@v1
```

- [ ] **Step 2: Validate the YAML parses**

Run: `bundle exec ruby -ryaml -e 'YAML.safe_load_file(".github/workflows/release.yml"); puts "ok"'`
Expected: `ok`.

- [ ] **Step 3: Verify trigger, permissions, and steps**

Run:
```bash
bundle exec ruby -ryaml -e '
  w = YAML.safe_load_file(".github/workflows/release.yml")
  # NOTE: YAML `on:` parses to the boolean key true, not the string "on".
  trigger = w[true] || w["on"]
  raise "wrong tag trigger" unless trigger.dig("push","tags") == ["v*.*.*"]
  perms = w.dig("jobs","publish","permissions")
  raise "missing id-token perm" unless perms["id-token"] == "write"
  raise "missing contents perm" unless perms["contents"] == "write"
  steps = w.dig("jobs","publish","steps").map { |s| s["uses"] || s["name"] || s["run"] }
  raise "missing release-gem" unless steps.any? { |s| s.to_s.include?("rubygems/release-gem") }
  puts "release shape ok"
'
```
Expected: `release shape ok`.

- [ ] **Step 4: Verify the version-guard shell logic in isolation**

Run (simulates the guard for a matching and a mismatching tag):
```bash
gem_version="$(ruby -Ilib -r http_connection_pool/version -e 'print HttpConnectionPool::VERSION')"
echo "resolved version: $gem_version"
# matching tag -> exit 0
GITHUB_REF_NAME="v$gem_version"; tag="${GITHUB_REF_NAME#v}"; [ "$gem_version" = "$tag" ] && echo "match ok"
# mismatching tag -> should be detected
GITHUB_REF_NAME="v9.9.9"; tag="${GITHUB_REF_NAME#v}"; [ "$gem_version" != "$tag" ] && echo "mismatch detected ok"
```
Expected: prints the version, `match ok`, and `mismatch detected ok`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add tag-triggered OIDC release workflow

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md` (add CI badge; replace the publishing paragraph; document the release flow + Trusted Publisher setup + MFA posture)
- Modify: `CLAUDE.md` (add CI + release section; add `bump:*` to the Rake-tasks table; note gemspec metadata; reaffirm user-only publish)

**Interfaces:**
- Consumes: the workflow names and metadata produced by Tasks 1–4.
- Produces: living docs consistent with the implemented behaviour. No later task depends on it.

- [ ] **Step 1: Add the CI status badge to the README**

At the very top of `README.md`, insert a badge line immediately after the `# HttpConnectionPool` H1 (blank line above and below):

```markdown
[![CI](https://github.com/bbarberBPL/http_connection_pool/actions/workflows/ci.yml/badge.svg)](https://github.com/bbarberBPL/http_connection_pool/actions/workflows/ci.yml)
```

- [ ] **Step 2: Replace the README publishing section**

In `README.md`, replace the two paragraphs under `### Building and publishing` that currently begin with "`rake build:checksum` records both digests…" and "Publishing to RubyGems is a manual, maintainer-only step…" — keep the existing `bundle exec rake build` / `build:checksum` fenced block above them — with:

````markdown
`rake build:checksum` records both digests under `checksums/` in the standard
`sha256sum -c` / `sha512sum -c` format, so a published artifact can be verified
against this repository. The built `.gem` is never committed; only its
checksums are.

#### Releasing

Releases are cut by bumping the version locally and pushing a matching tag; a
GitHub Actions workflow then tests and publishes to RubyGems over OIDC (no API
key is stored anywhere). The maintainer pushes the tag — the workflow runs the
`gem push`.

```bash
bundle exec rake bump:patch   # 0.1.0 -> 0.1.1; rewrites version.rb + checksums/
git add lib/http_connection_pool/version.rb checksums/
git commit -m 'Release v0.1.1'
git tag v0.1.1
git push && git push --tags   # the tag push triggers the release workflow
```

Use `bump:minor` or `bump:major` for those components. On the `v*.*.*` tag,
`.github/workflows/release.yml` verifies the tag matches
`HttpConnectionPool::VERSION`, re-runs the specs, verifies the committed
checksums match a fresh build, and publishes via `rubygems/release-gem`.

**One-time setup (maintainer, on rubygems.org):** register this repository as a
Trusted Publisher before the first release. On rubygems.org, add a GitHub
Actions trusted publisher for repository `bbarberBPL/http_connection_pool` and
workflow `release.yml` (for the not-yet-published gem, add it as a *pending*
trusted publisher under your profile's OIDC settings; afterwards it lives on the
gem's *Trusted Publishers* page). Until this exists, the publish step fails.

The gem sets `rubygems_mfa_required`, so all privileged interactive operations
(yank, ownership, manual pushes, API-key management) require your authenticator
app. OIDC Trusted Publishing satisfies this MFA requirement for automated
releases — the verified GitHub Actions identity is the second factor — so no
one-time-password prompt appears in CI.
````

- [ ] **Step 3: Verify the README has no stale "no automated push" wording**

Run: `grep -n 'no automated push\|manual, maintainer-only step' README.md`
Expected: no matches (the old wording is gone).

- [ ] **Step 4: Update the CLAUDE.md Rake-tasks table**

In `CLAUDE.md`, in the Rake Tasks table, add these rows (after the `rake build:checksum` row):

```markdown
| `rake bump:patch`     | Bump patch version in version.rb, regenerate checksums |
| `rake bump:minor`     | Bump minor version in version.rb, regenerate checksums |
| `rake bump:major`     | Bump major version in version.rb, regenerate checksums |
```

- [ ] **Step 5: Add a CI + release subsection to CLAUDE.md**

In `CLAUDE.md`, in the `## Publishing and release` section, after the existing bullet list, add:

```markdown
### Continuous integration

- `.github/workflows/ci.yml` runs on push to `main` and on PRs: a `test` matrix
  over MRI Ruby `3.3` and `3.4` running `rake ci`, plus a separate `security`
  job running `rake audit` (network advisory-DB refresh + check). MRI only — no
  JRuby/TruffleRuby matrix (the `max_pools` soft-cap spec is GVL-dependent).
- `.github/workflows/release.yml` triggers on a `v*.*.*` tag: it verifies the
  tag matches `HttpConnectionPool::VERSION`, re-runs the specs, verifies the
  committed checksums against a fresh build, then publishes via
  `rubygems/release-gem` over OIDC Trusted Publishing. No RubyGems API key is
  stored; `id-token: write` mints a short-lived token per release.
- **The release is still user-initiated:** a human runs `rake bump:*`, commits,
  and pushes the tag. The assistant authors these workflows but never runs
  `gem push` or `git push`. Pushing the tag is what a maintainer does.
- Gemspec carries `rubygems_mfa_required = 'true'`; interactive privileged
  operations need the maintainer's authenticator app, while OIDC publishing is
  accepted as MFA-compliant. Gemspec also sets `homepage`, `metadata['homepage_uri']`,
  and `metadata['source_code_uri']`.
```

- [ ] **Step 6: Verify docs are internally consistent**

Run: `grep -n 'bump:' README.md CLAUDE.md && grep -n 'rubygems_mfa_required\|Trusted Publish' README.md CLAUDE.md`
Expected: both files mention the `bump:*` tasks, MFA metadata, and Trusted Publishing.

- [ ] **Step 7: Run the full CI task to confirm nothing regressed**

Run: `bundle exec rake ci`
Expected: green (RuboCop clean including the new files; all specs pass).

- [ ] **Step 8: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document CI, release flow, and MFA posture

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- CI two-job layout (test matrix 3.3/3.4 + security) → Task 3. ✓
- `rake bump:{patch,minor,major}`, no git ops, regenerates checksums → Task 2. ✓
- Release workflow: tag trigger, version guard, specs-only re-run, checksum gate, OIDC publish → Task 4. ✓
- MFA via `rubygems_mfa_required` metadata → Task 1. ✓
- Gemspec homepage / homepage_uri / source_code_uri → Task 1. ✓
- Verify against http 6.0.4 (no gemspec change) → Task 1, Step 6. ✓
- One-time Trusted Publisher setup documented → Task 5, Step 2. ✓
- README badge + release flow; CLAUDE.md CI/release section + Rake table → Task 5. ✓
- `tasks/` not packaged (spec.files globs lib only) → Global Constraints + Task 2 comment. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". All code blocks are concrete. ✓

**Type consistency:** `VersionBumper.next(current, level)` defined in Task 2 Step 3 and consumed by the Rakefile task in the same task; signature and `LEVELS` constant match between the helper, the spec, and the Rakefile usage. Workflow job names (`test`, `security`, `publish`) are consistent between Tasks 3/4 and the Task 3/4 verification steps and Task 5 badge. ✓
