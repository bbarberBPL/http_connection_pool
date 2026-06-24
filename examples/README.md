# Examples

Runnable examples that show `http_connection_pool` against a real backend.
These are illustrative — they are not part of the gem package or the test
suite, and they are not loaded by the library.

## Solr client

[`solr_client.rb`](solr_client.rb) defines `SolrClient`, a `Connectable` client
for a Solr 8.11.x core. It keeps one persistent, keep-alive connection pool per
Solr origin and layers JSON request/response handling on top:

- `upsert(**fields)` — add or replace a document (full-document overwrite by
  `id`, committing immediately).
- `find(id)` — fetch one document via Solr's real-time get handler.
- `delete(id)` — delete one document by `id`.
- `count` — number of documents in the core.

[`solr_update_demo.rb`](solr_update_demo.rb) is a runnable round-trip: it POSTs
an initial document, overwrites it with an updated version, performs many reads
to show pool reuse, then deletes the document. It operates only on a throwaway
`id` (`example:hcp_update_demo`) and cleans up after itself, so it never
mutates real data.

### Running it

The examples assume a Solr instance reachable at `http://localhost:8983` with a
core named `curator_development`. Override either with environment variables:

```bash
# Against the default local Solr:
bundle exec ruby examples/solr_update_demo.rb

# Against a different instance / core:
SOLR_URL=http://solr.internal:8983 SOLR_CORE=my_core \
  bundle exec ruby examples/solr_update_demo.rb
```

Expected output ends with `Done. Real data untouched.` and a document count
equal to where it started.

### A note on update styles

Solr supports two ways to update a document:

1. **Full-document overwrite** (what this example uses) — POST the whole
   document by `id`. Solr replaces any existing document with the same
   uniqueKey. This is the portable path and works on any core.
2. **Atomic partial update** — POST `[{ id: ..., field: { set: value } }]` to
   change one field without resending the document. This is **not universally
   available**: a core configured with an update-request processor that needs
   the full document (for example a `SignatureUpdateProcessor` keyed on `id`,
   as the Curator development core is) rejects partial updates with an HTTP
   500. Confirm your target core permits atomic updates before relying on them;
   otherwise prefer the full overwrite.
