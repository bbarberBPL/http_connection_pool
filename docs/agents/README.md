# Agents

Project-specific subagent definitions for `http_connection_pool`.

When a task in this project benefits from a dedicated subagent (a focused
reviewer, a migration helper, a release auditor, etc.), define it here as one
Markdown file per agent. Keep each agent's responsibility narrow and its
instructions self-contained, so it can run without the parent session's
context.

## File convention

- One file per agent: `docs/agents/<agent-name>.md`.
- Start with a short purpose line: what the agent does and when to reach for it.
- List the tools it needs and the inputs it expects (file paths, not pasted
  context).
- Describe the report format it must return.

No agents are defined yet.
