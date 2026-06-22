---
name: dependency-audit
description: Use when reviewing this gem's dependencies for security issues or available patches — before a release, when a dependency's changelog mentions a fix, or on a periodic security sweep. Verifies every advisory/version claim against primary sources before recommending any change.
---

# Dependency audit

A repeatable security sweep of `http_connection_pool`'s dependency tree. The
rule that makes this trustworthy: **changelogs and AI summaries are leads, not
facts** — confirm each against RubyGems and the GitHub advisory DB before acting.
(A prior session nearly pinned the `http` floor to an unpublished `6.0.4` citing
a GHSA that 404'd; this workflow exists so that never ships.)

For a deep, multi-gem audit, dispatch the
[`dependency-security-auditor`](../../agents/dependency-security-auditor.md)
agent instead of running these steps inline.

## Steps

1. **Enumerate the tree.** Read runtime deps in `http_connection_pool.gemspec`
   and the dev/test groups in `Gemfile`. Capture each gem's resolved version:

   ```bash
   bundle exec ruby -e "%w[http connection_pool concurrent-ruby].each { |g| s = Gem.loaded_specs[g]; puts format('%-18s %s', g, s&.version) }"
   ```

2. **Run the offline audit:**

   ```bash
   bundle exec bundle-audit check
   ```

3. **Gather leads.** Skim each dependency's CHANGELOG for entries that mention a
   security fix, CVE, or GHSA. Note the claimed patched version and advisory ID.

4. **Verify each lead against primary sources — do not skip this:**

   ```bash
   # Is the patched version actually PUBLISHED (not just on the changelog's main)?
   curl -s https://rubygems.org/api/v1/versions/<gem>.json | python3 -c "import sys,json; [print(v['number'], v['created_at'][:10]) for v in json.load(sys.stdin)[:8]]"

   # Does the advisory actually resolve (expect JSON, not 404)?
   curl -s https://api.github.com/advisories/<GHSA-ID>

   # Real advisories affecting this gem, with version ranges:
   curl -s "https://api.github.com/advisories?ecosystem=rubygems&affects=<gem>"
   ```

   Confirm the advisory's vulnerable range actually includes our resolved
   version, and that the patched version exists on RubyGems.

5. **Decide and report.** For each verified issue: does it affect our version, is
   the fix installable today, and would a floor bump break installs or the Rails
   shared-dep overlap (see CLAUDE.md)? Recommend the exact gemspec/Gemfile change.

   - **Never pin a floor to an unpublished version** — it makes the gem
     uninstallable. If the fix is unpublished, record it as a watch-item in the
     README security section and the gemspec comment, and bump the floor only
     once the version ships.
   - Dependency-bump edits are a human decision — propose, don't auto-apply.

6. **Keep CI green.** After any dependency change, `bundle exec rake ci` must
   pass (bundler-audit → RuboCop → RSpec).
