# frozen_string_literal: true

# Capture a catalog from a machine that can reach the manufacturer, then load it
# into an environment that cannot.
#
# Adventure Homes is hosted on SiteGround, whose Anti-Bot AI challenges our
# Render egress IPs: every request from staging or prod comes back 202 with a
# captcha stub. A laptop gets 200. Until they allowlist us, capture here and
# push, and the platform runs the real ingestion path against stored homes.
#
#   bin/rails 'catalog:homes_snapshot:capture[19]'
#   bin/rails 'catalog:homes_snapshot:push[adventure_homes,https://renterinsight-api-staging.onrender.com]'
#
# Re-capturing later is the refresh: IngestionService diffs each home's
# content_hash, so a second push updates only what actually changed, inactivates
# what disappeared, and leaves dealer edits alone.
namespace :catalog do
  namespace :homes_snapshot do
    DEFAULT_DIR = Rails.root.join('tmp/catalog_snapshots')

    desc 'Crawl a source live and write a snapshot JSON file (run where the site is reachable)'
    task :capture, %i[source_id key limit] => :environment do |_t, args|
      source = CatalogSource.find(args[:source_id])
      key    = args[:key].presence || source.name.to_s.parameterize(separator: '_')
      limit  = args[:limit].presence&.to_i

      adapter = source.adapter
      abort "No adapter for #{source.adapter_type}" if adapter.nil?
      if adapter.respond_to?(:snapshot_key) && adapter.snapshot_key.present?
        abort "Source #{source.id} is bound to snapshot '#{adapter.snapshot_key}'. " \
              'Clear config.snapshot_key before capturing, or you will re-capture the snapshot.'
      end

      keys = Array(adapter.discover(limit: limit))
      puts "Discovered #{keys.size} homes from #{source.base_url}"
      abort 'Discovery returned nothing — captured nothing.' if keys.empty?

      homes  = []
      failed = []
      keys.each_with_index do |source_key, index|
        raw  = adapter.fetch(source_key)
        home = raw && adapter.parse(raw)
        if home&.model_name.present?
          homes << home
        else
          failed << source_key
        end
        print "\r  #{index + 1}/#{keys.size} (#{failed.size} failed)"
        sleep adapter.crawl_delay if index < keys.size - 1
      end
      puts

      abort 'Every home failed to parse — refusing to write an empty snapshot.' if homes.empty?

      payload = Catalog::HomesSnapshot.build(source: source, homes: homes)
      FileUtils.mkdir_p(DEFAULT_DIR)
      path = DEFAULT_DIR.join("#{key}.json")
      File.write(path, JSON.pretty_generate(payload))

      smoke = homes.count(&:valid_smoke?)
      puts "Captured #{homes.size} homes (#{smoke} pass smoke, #{failed.size} failed) -> #{path}"
      puts "  size: #{(File.size(path) / 1024.0).round}KB"
      puts "  failed keys: #{failed.first(10).join(', ')}#{'...' if failed.size > 10}" if failed.any?
      puts "Next: bin/rails 'catalog:homes_snapshot:push[#{key},<api_base_url>]'"
    end

    desc 'Upload a captured snapshot to an environment (env: CATALOG_API_TOKEN, optional SOURCE_ID)'
    task :push, %i[key api_base] => :environment do |_t, args|
      key      = args[:key].presence or abort 'Usage: push[key,api_base]'
      api_base = args[:api_base].presence or abort 'Usage: push[key,api_base]'
      token    = ENV['CATALOG_API_TOKEN'].presence or
                 abort 'Set CATALOG_API_TOKEN to a platform-admin JWT'

      path = DEFAULT_DIR.join("#{key}.json")
      abort "No snapshot at #{path} — run capture first" unless File.exist?(path)

      payload = JSON.parse(File.read(path))
      body    = { snapshot: payload, key: key }
      body[:source_id] = ENV['SOURCE_ID'] if ENV['SOURCE_ID'].present?

      uri = URI.join(api_base, '/api/admin/catalog_sources/upload_snapshot')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type']  = 'application/json'
      request['Authorization'] = "Bearer #{token}"
      request.body = body.to_json

      response = http.request(request)
      puts "HTTP #{response.code}"
      puts response.body
      abort 'Upload failed' unless response.is_a?(Net::HTTPSuccess)
      puts "Loaded '#{key}' (#{Array(payload['homes']).size} homes). Run Now on the source to ingest."
    end

    desc 'List snapshots stored in THIS environment'
    task list: :environment do
      keys = Catalog::HomesSnapshot.keys
      abort 'No snapshots stored.' if keys.empty?

      keys.each do |key|
        snap = Catalog::HomesSnapshot.read(key) || {}
        puts format('%-28s %5d homes  captured %s', key, Array(snap['homes']).size,
                    snap['captured_at'] || 'unknown')
      end
    end
  end
end
