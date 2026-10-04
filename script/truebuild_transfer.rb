#!/usr/bin/env ruby
# frozen_string_literal: true

# Copies TrueView work already paid for from one environment to another:
# decor samples, chosen photos, outlines, then drawings. Plain Ruby, run from
# a laptop; both ends are the admin API (Truebuild::DrawingTransfer).
#
#   FROM_URL=https://renterinsight-api-staging.onrender.com FROM_TOKEN=... \
#   TO_URL=https://api.dealertide.com TO_TOKEN=... \
#   ruby script/truebuild_transfer.rb [kinds] [--dry-run]
#
# Tokens are a platform admin's sign-in token on each side (localStorage
# authToken in the browser). kinds defaults to swatches,photos,masks,renders.
# Safe to run again: what the receiving side already has is left alone, and
# the run resumes from the start each time. --dry-run only counts.
#
# Publish the same price books on the receiving side first: drawings are
# found by their prompt, which comes from the book's option names and the
# factory's samples.

require 'json'
require 'net/http'
require 'uri'

KINDS = %w[swatches photos masks renders].freeze
BATCH = { 'swatches' => 50, 'photos' => 100, 'masks' => 20, 'renders' => 15 }.freeze # rows a request; each file is copied

def env!(key)
  ENV.fetch(key) { abort "Set #{key}" }
end

def call(method, base, token, path, body = nil)
  uri = URI.join(base, path)
  req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 600) { |h| h.request(req) }
  abort "#{method.upcase} #{uri} -> #{res.code}: #{res.body.to_s[0, 300]}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

from, from_token, to, to_token = env!('FROM_URL'), env!('FROM_TOKEN'), env!('TO_URL'), env!('TO_TOKEN')
dry = ARGV.delete('--dry-run')
kinds = ARGV.first ? ARGV.first.split(',') : KINDS
abort "kinds: #{KINDS.join(',')}" unless (kinds - KINDS).empty?

kinds.each do |kind|
  after = 0
  totals = Hash.new(0)
  skipped = []
  loop do
    page = call(:get, from, from_token, "/api/admin/trueview_transfer?kind=#{kind}&after_id=#{after}&limit=#{BATCH[kind]}")
    rows = page['rows']
    break if rows.empty?

    if dry
      totals['found'] += rows.size
    else
      result = call(:post, to, to_token, '/api/admin/trueview_transfer', { kind: kind, rows: rows })
      %w[created updated].each { |k| totals[k] += result[k].to_i }
      skipped.concat(result['skipped'])
    end
    print "\r#{kind}: #{totals.map { |k, v| "#{v} #{k}" }.join(', ')}#{", #{skipped.size} skipped" if skipped.any?}"
    after = page['next_after']
    break unless after
  end
  puts
  skipped.first(20).each { |s| puts "  skipped #{s}" }
  puts "  ... and #{skipped.size - 20} more" if skipped.size > 20
end
