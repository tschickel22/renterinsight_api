# frozen_string_literal: true

# Rehost manufacturer imagery already sitting on vehicles.
#
# Wiring the archiver into RunService only helps homes ingested from now on;
# vehicles already in the database still point at CloudFront, Bunny and Clayton.
# This walks them and rewrites each image to our own copy.
#
#   bin/rails catalog:images:report
#   bin/rails 'catalog:images:backfill[47]'      # one source
#   bin/rails catalog:images:backfill            # every catalog source
#
# Safe to re-run: keys are content-addressed, so a second pass re-uses what is
# already in the bucket instead of uploading again.
namespace :catalog do
  namespace :images do
    desc 'Show how much manufacturer imagery is still hot-linked'
    task report: :environment do
      scope = Vehicle.where.not(catalog_source_id: nil).where(is_deleted: [false, nil])
      hosts = Hash.new(0)
      hosted = 0
      remote = 0

      scope.find_each do |vehicle|
        images_of(vehicle).each do |img|
          if img['local_url'].present?
            hosted += 1
            next
          end

          url = img['url'] || img['source_url']
          next if url.blank?

          remote += 1
          hosts[safe_host(url)] += 1
        end
      end

      puts "vehicles: #{scope.count}"
      puts "images already rehosted: #{hosted}"
      puts "images still hot-linked: #{remote}"
      hosts.sort_by { |_, v| -v }.each { |host, n| puts format('   %-40s %d', host, n) }
    end

    desc 'Rehost imagery for catalog vehicles [source_id,limit]'
    task :backfill, %i[source_id limit] => :environment do |_t, args|
      # A first run should be inspectable. Without a limit the smallest real
      # source is still ~1,100 images, which is minutes of downloading before
      # you can look at a single result and confirm the URLs actually resolve.
      limit = args[:limit].presence&.to_i
      sources = if args[:source_id].present?
                  CatalogSource.where(id: args[:source_id])
                else
                  CatalogSource.where(id: Vehicle.where.not(catalog_source_id: nil)
                                                 .distinct.pluck(:catalog_source_id))
                end

      if sources.empty?
        puts 'No catalog sources to process.'
        next
      end

      sources.each do |source|
        vehicles = Vehicle.where(catalog_source_id: source.id, is_deleted: [false, nil]).order(:id)
        vehicles = vehicles.limit(limit) if limit
        next if vehicles.empty?

        puts "#{source.name} — #{vehicles.count} vehicles#{limit ? " (limited to #{limit})" : ''}"
        # One archiver per source: it lists the bucket once and carries that
        # set across every vehicle, so the whole backfill costs one listing.
        archiver = Catalog::ImageArchiver.new(crawl_delay: source.config.to_h['image_crawl_delay'].to_i)
        touched = 0

        # find_each ignores a scoped limit (and says so in a warning), so a
        # limited run has to iterate normally. The row count is small by
        # definition in that case.
        iterator = limit ? vehicles.to_a : vehicles
        iterator.each do |vehicle|
          gallery = archiver.archive(normalize(images_of(vehicle)))
          plans   = archiver.archive(normalize(images_of(vehicle, :floor_plan_images)))

          updates = {}
          updates[:images] = to_vehicle_images(gallery) if changed?(vehicle.images, gallery)
          updates[:floor_plan_images] = to_vehicle_images(plans) if changed?(vehicle.floor_plan_images, plans)
          primary = to_vehicle_images(gallery).first
          updates[:photo_url] = primary['url'] if primary && vehicle.photo_url != primary['url']

          next if updates.empty?

          # update_columns: this is a media rehost, not a catalog change. Going
          # through callbacks would re-run normalisation and bump updated_at on
          # thousands of rows for no reason.
          vehicle.update_columns(updates)
          touched += 1
        end

        r = archiver.result
        puts "   rehosted #{r.archived}, already held #{r.reused}, failed #{r.failed} " \
             "(#{touched} vehicles updated)"
      end
    end

    # ---- helpers ----------------------------------------------------------

    def images_of(vehicle, field = :images)
      Array(vehicle.public_send(field)).select { |i| i.is_a?(Hash) }
    end

    # Vehicles store { url, alt }; the archiver speaks { source_url, local_url }.
    def normalize(images)
      images.map do |img|
        url = img['url'] || img['source_url']
        { 'source_url' => url, 'local_url' => nil, 'alt' => img['alt'] }
      end
    end

    # ...and back again, preferring our copy where we have one.
    def to_vehicle_images(archived)
      archived.filter_map do |img|
        url = img['local_url'].presence || img['source_url']
        next if url.blank?

        { 'url' => url, 'alt' => img['alt'].to_s }
      end
    end

    def changed?(before, after)
      Array(before).map { |i| i.is_a?(Hash) ? i['url'] : i } != to_vehicle_images(after).map { |i| i['url'] }
    end

    def safe_host(url)
      URI.parse(url).host || '(unparseable)'
    rescue StandardError
      '(unparseable)'
    end
  end
end
