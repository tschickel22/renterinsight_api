# frozen_string_literal: true

# Load / inspect captured Trove catalog snapshots.
#
# Trove hosts answer 429 to any non-browser client (Vercel bot checkpoint), so
# until a host allowlists us a source runs from a snapshot captured out of band.
# The adapter parses snapshot and live data through the same extractors, so a
# snapshot-backed run is a faithful rehearsal of a live one.
#
#   bin/rails 'catalog:snapshot:load[db/catalog_snapshots/trove_legacy_housing.json,legacy_housing]'
#   bin/rails catalog:snapshot:list
#   bin/rails 'catalog:snapshot:source[legacy_housing]'
namespace :catalog do
  namespace :snapshot do
    desc 'Load a Trove snapshot JSON file into platform settings [path,key]'
    task :load, %i[path key] => :environment do |_t, args|
      path = args[:path].to_s
      abort "Usage: rake 'catalog:snapshot:load[path,key]'" if path.blank?
      abort "No such file: #{path}" unless File.exist?(path)

      payload = JSON.parse(File.read(path))
      key     = args[:key].presence || File.basename(path, '.json')

      Catalog::TroveSnapshot.write(key, payload)

      homes  = Array(payload['homes'])
      images = homes.sum { |h| Array(h['images']).size }
      puts "Loaded snapshot '#{key}'"
      puts "  supplier   : #{payload['supplier_name']}"
      puts "  base_url   : #{payload['base_url']}"
      puts "  captured   : #{payload['captured_at']}"
      puts "  homes      : #{homes.size}"
      puts "  images     : #{images} (avg #{(images.to_f / [homes.size, 1].max).round(1)}/home)"
      puts "  no images  : #{homes.count { |h| Array(h['images']).empty? }}"
    end

    desc 'List stored snapshots'
    task list: :environment do
      keys = Catalog::TroveSnapshot.keys
      if keys.empty?
        puts 'No snapshots stored.'
        next
      end

      keys.each do |key|
        snap = Catalog::TroveSnapshot.read(key)
        puts format('%-24s %-18s %s homes  captured %s',
                    key, snap['supplier_name'], Array(snap['homes']).size, snap['captured_at'])
      end
    end

    desc 'Create (or update) a catalog source backed by a stored snapshot [key]'
    task :source, [:key] => :environment do |_t, args|
      key = args[:key].to_s
      abort "Usage: rake 'catalog:snapshot:source[key]'" if key.blank?

      snap = Catalog::TroveSnapshot.read(key)
      abort "No snapshot stored under '#{key}'. Run catalog:snapshot:load first." if snap.blank?

      name   = "#{snap['supplier_name']} (Trove)"
      source = CatalogSource.find_or_initialize_by(name: name)
      source.assign_attributes(
        adapter_type: 'trove_catalog',
        base_url:     snap['base_url'],
        enabled:      true,
        schedule:     'manual',
        config: (source.config || {}).merge(
          'snapshot_key' => key,
          'crawl_delay'  => 5,
          # Legacy publishes the description scaffold with empty bodies on every
          # record, so a clean run would otherwise be impossible.
          'untracked_fields' => %w[description]
        )
      )
      source.save!

      puts "#{source.previously_new_record? ? 'Created' : 'Updated'} catalog source ##{source.id} — #{source.name}"
      puts "  adapter : #{source.adapter_type}"
      puts "  snapshot: #{key} (#{Array(snap['homes']).size} homes)"
    end
  end
end
