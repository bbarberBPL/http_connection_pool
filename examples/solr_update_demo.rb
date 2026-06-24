#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative 'solr_client'

# Runnable demonstration of a Solr update round-trip through the pooled client.
# It operates ONLY on a throwaway document id so it never touches real data,
# and deletes that document at the end. Run against the local dev Solr:
#
#   bundle exec ruby examples/solr_update_demo.rb
#
# Override the target with SOLR_URL / SOLR_CORE if needed.

CORE = ENV.fetch('SOLR_CORE', 'curator_development')
DEMO_ID = 'example:hcp_update_demo'
DIVIDER = ('-' * 60).freeze

client = SolrClient.new(core: CORE)

puts DIVIDER
puts "Solr update demo — core=#{CORE} at #{SolrClient.base_url}"
puts "starting document count: #{client.count}"
puts DIVIDER

puts "\n1. POST initial version of #{DEMO_ID}"
client.upsert(
  id: DEMO_ID,
  title_info_primary_tsi: 'Pooled client demo (v1)',
  processing_state_ssi: 'initial'
)
doc = client.find(DEMO_ID)
puts "   title: #{doc['title_info_primary_tsi']}"
puts "   state: #{doc['processing_state_ssi']}"

puts "\n2. POST updated version (full-document overwrite by id)"
client.upsert(
  id: DEMO_ID,
  title_info_primary_tsi: 'Pooled client demo (v2 — updated)',
  processing_state_ssi: 'derivatives'
)
doc = client.find(DEMO_ID)
puts "   title: #{doc['title_info_primary_tsi']}"
puts "   state: #{doc['processing_state_ssi']}"

puts "\n3. Pool reuse check — many reads share one connection"
20.times { client.find(DEMO_ID) }
stats = SolrClient.connection_pool_stats
puts "   pool: size=#{stats[:size]} checked_out=#{stats[:checked_out]} idle=#{stats[:idle]}"

puts "\n4. Clean up — delete #{DEMO_ID}"
client.delete(DEMO_ID)
puts "   found after delete: #{client.find(DEMO_ID).inspect}"
puts "   final document count: #{client.count}"

puts "\n#{DIVIDER}"
puts 'Done. Real data untouched.'
