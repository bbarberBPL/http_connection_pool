# Skills

Project-specific skills for `http_connection_pool`.

When a repeatable workflow emerges in this project (a release checklist, a
dependency-audit routine, a benchmark-and-compare procedure), capture it here
as a skill so future sessions follow the same steps instead of rediscovering
them.

## File convention

- One directory per skill: `docs/skills/<skill-name>/SKILL.md`.
- The `SKILL.md` opens with YAML frontmatter (`name`, `description`) describing
  when the skill applies, followed by the steps.
- Keep steps concrete and ordered; prefer checklists the session can turn into
  todos.
- Reference supporting files by relative path within the skill directory.

## Defined skills

- [`dependency-audit`](dependency-audit/SKILL.md) — security sweep of the
  dependency tree that verifies every advisory/version claim against primary
  sources (RubyGems API, GitHub advisory DB) before recommending a change.
