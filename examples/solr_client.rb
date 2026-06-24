# frozen_string_literal: true

require 'http_connection_pool'
require 'json'

# Example: a pooled Solr 8.11.x client built on the Connectable mixin.
#
# This shows the gem's intended shape for a real backend: one persistent,
# keep-alive connection pool per Solr origin, shared across every request and
# every thread, with JSON request/response handling layered on top.
#
# It targets a single core (collection). Solr's update handlers commit through
# the `/update` endpoints; here we use a full-document overwrite by `id`, which
# is the portable update path (see SOLR_UPDATE_NOTES below).
#
# Usage:
#   client = SolrClient.new(core: 'curator_development')
#   client.upsert(id: 'demo:1', title_info_primary_tsi: 'Hello')
#   client.find('demo:1')
#   client.delete('demo:1')
class SolrClient
  include HttpConnectionPool::Connectable

  # Point at the local Solr. Override with SOLR_URL for a different instance.
  self.base_url     = ENV.fetch('SOLR_URL', 'http://localhost:8983')
  self.pool_size    = 5
  self.pool_timeout = 5.0
  self.pool_options = { headers: { 'Content-Type' => 'application/json' } }

  def initialize(core:)
    @core = core
  end

  attr_reader :core

  # Add or replace a document. Solr overwrites any existing document with the
  # same uniqueKey (`id`), so this is an upsert. `commit=true` makes the change
  # immediately visible (fine for an example; batch + soft-commit in production).
  #
  # @param fields [Hash] the full document, including its `id`
  # @return [Hash] the parsed Solr responseHeader
  def upsert(**fields)
    raise ArgumentError, 'document must include :id' unless fields.key?(:id)

    post_json("/solr/#{core}/update/json/docs?commit=true", fields)
  end

  # Fetch a single document by id via Solr's real-time get handler.
  #
  # @return [Hash, nil] the document, or nil if it does not exist
  def find(id)
    response = with_connection do |conn|
      conn.get("/solr/#{core}/get", params: { id: id })
    end
    JSON.parse(response.to_s).fetch('doc', nil)
  end

  # Delete a document by id, committing immediately.
  #
  # @return [Hash] the parsed Solr responseHeader
  def delete(id)
    post_json("/solr/#{core}/update?commit=true", delete: { id: id })
  end

  # Number of documents in the core.
  #
  # @return [Integer]
  def count
    response = with_connection do |conn|
      conn.get("/solr/#{core}/select", params: { q: '*:*', rows: 0, wt: 'json' })
    end
    JSON.parse(response.to_s).dig('response', 'numFound')
  end

  private

  def post_json(path, payload)
    response = with_connection do |conn|
      conn.post(path, body: JSON.generate(payload))
    end
    body = JSON.parse(response.to_s)
    raise "Solr error (#{response.code}): #{body.dig('error', 'msg') || body}" unless response.status.success?

    body.fetch('responseHeader', body)
  end
end

# SOLR_UPDATE_NOTES
#
# Solr supports two update styles:
#
#   1. Full-document overwrite (used here) — POST the whole document by `id`.
#      Portable; works on any core.
#
#   2. Atomic partial update — POST `[{ id: ..., field: { set: value } }]`.
#      Updates one field without resending the document, but it is NOT
#      universally available: a core configured with an update-request
#      processor that reads the whole document (e.g. SignatureUpdateProcessor
#      keyed on `id`, as the Curator dev core is) rejects partial updates with
#      a 500. Prefer the full overwrite unless you have confirmed the target
#      core permits atomic updates.
