# Supplement an existing dealer's inventory with data scraped from a manufacturer
# catalog source (images, dimensions, specs, etc.) — WITHOUT creating duplicates
# and WITHOUT subscribing them to the source (which would import all rows as new
# ATO vehicles). Once supplemented, vehicles carry catalog_source_id +
# catalog_source_key so a future subscription/re-sync recognizes them and only
# refreshes catalog-managed fields the dealer hasn't touched.
#
#   bin/rails 'catalog:preview_match[17,2]'            # dry-run report, Sunshine→Evangeline
#   bin/rails 'catalog:supplement[17,2]'               # dry-run apply (default)
#   bin/rails 'catalog:supplement[17,2]' RUN=1         # actually persist

namespace :catalog do
  desc 'Dry-run match: which existing vehicles would each catalog home supplement? [company_id, catalog_source_id]'
  task :preview_match, %i[company_id catalog_source_id] => :environment do |_, args|
    company, source = load_args(args)
    puts "preview_match  |  company=#{company.id} (#{company.name})  |  source=#{source.id} (#{source.name})"
    puts '-' * 100

    matches = Catalog::SupplementMatcher.new(company: company, source: source).call

    puts format('%-35s | %-6s | %-30s | %-9s | %s', 'catalog_key', 'conf', 'matched_vehicle', 'stamped?', 'reason')
    puts '-' * 100

    counts = Hash.new(0)
    matches.each do |m|
      conf = m.confidence&.to_s || 'none'
      counts[conf] += 1
      vid_label = m.vehicle ? "##{m.vehicle.id} #{[m.vehicle.make, m.vehicle.model].compact.join(' ').strip[0, 28]}" : '—'
      stamped = m.vehicle && m.vehicle.catalog_source_id.present? ? 'yes' : 'no'
      puts format('%-35s | %-6s | %-30s | %-9s | %s',
                  m.home.source_key.to_s[0, 35], conf, vid_label, stamped, m.reason.to_s)
    end

    puts ''
    puts "Summary  high=#{counts['high']}  medium=#{counts['medium']}  low=#{counts['low']}  none=#{counts['none']}  total=#{matches.size}"
  end

  desc 'Supplement matched vehicles with catalog data (blanks only). RUN=1 to apply. [company_id, catalog_source_id]'
  task :supplement, %i[company_id catalog_source_id] => :environment do |_, args|
    company, source = load_args(args)
    apply = ENV['RUN'] == '1'
    mode  = apply ? 'APPLY MODE — writes will persist' : 'DRY RUN — no writes (set RUN=1 to apply)'
    puts "supplement  |  #{mode}  |  company=#{company.id} (#{company.name})  |  source=#{source.id} (#{source.name})"
    puts '-' * 100

    matches = Catalog::SupplementMatcher.new(company: company, source: source).call
    result  = Catalog::SupplementApplier.new(matches: matches, source: source, dry_run: !apply).call

    puts ''
    puts "Stamped (catalog ids written onto existing vehicle):   #{result.stamped}"
    puts "Fields filled (blank → catalog value, across all):     #{result.fields_filled}"
    puts "Skipped (vehicle already linked to a catalog source):  #{result.skipped_already_stamped}"
    puts "Unmatched catalog homes (would become new ATO on sync):#{result.unmatched}"
    puts ''
    puts(apply ? 'Supplement APPLIED.' : 'DRY RUN complete — re-run with RUN=1 to persist.')
  end

  def load_args(args)
    company_id = args[:company_id].presence&.to_i
    source_id  = args[:catalog_source_id].presence&.to_i
    abort 'Usage: rails catalog:preview_match[company_id, catalog_source_id]' if company_id.nil? || source_id.nil?

    company = Company.find(company_id)
    source  = CatalogSource.find(source_id)
    [company, source]
  end
end
