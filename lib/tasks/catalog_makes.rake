# frozen_string_literal: true

# Repair the make on homes already pulled from a catalog.
#
# The make was the source's own name, which is an operator's label rather than a
# manufacturer: every card read "2026 Clayton — Acme Homes, Llc (Monroe, NC)
# EMILIE ELITE", and the city in it belongs to the retailer, not the home.
# Ingestion writes the manufacturer now, but only for homes pulled from here on.
#
#   bin/rails catalog:makes:report
#   bin/rails 'catalog:makes:backfill[47]'   # one source
#   bin/rails catalog:makes:backfill         # every catalog source
#
# Only rows whose make is still the source's label are touched, so a make a
# dealer has corrected by hand is left exactly as they left it.
module CatalogMakeTasks
  module_function

  # Homes still carrying the label. A dealer who has edited the make by hand no
  # longer matches, which is the point: their edit is the better answer.
  def mislabelled(source)
    Vehicle.where(catalog_source_id: source.id, make: source.name)
  end

  def each_source(only = nil)
    scope = CatalogSource.where(is_deleted: [false, nil])
    scope = scope.where(id: only) if only.present?

    scope.order(:id).each do |source|
      yield source, mislabelled(source).count, Catalog::ManufacturerName.for(source)
    end
  end
end

namespace :catalog do
  namespace :makes do
    desc 'Show which catalog homes carry an operator label as their make'
    task report: :environment do
      CatalogMakeTasks.each_source do |source, wrong, corrected|
        next if wrong.zero?

        puts format('%-6s %-48s %5d homes  ->  %s', source.id, source.name.to_s[0, 48], wrong, corrected)
      end
    end

    desc 'Rewrite the make on catalog homes that still carry the source label'
    task :backfill, [:source_id] => :environment do |_t, args|
      total = 0

      CatalogMakeTasks.each_source(args[:source_id]) do |source, wrong, corrected|
        next if wrong.zero? || corrected == source.name

        updated = CatalogMakeTasks.mislabelled(source).update_all(make: corrected, updated_at: Time.current)
        total += updated
        puts "#{source.name} -> #{corrected}: #{updated} homes"
      end

      puts "#{total} homes corrected"
    end
  end
end
