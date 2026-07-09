# Backfill deal.vehicle_id and deal_products.product_id for deals with a
# "home" line item whose vehicle link was never persisted.
#
# Root cause (now fixed forward in DealForm + DealProductsController): the FE
# stripped sourceId from the bulk_create payload and the BE didn't extract
# product_id from the transformed item. Any deal saved before those two fixes
# is orphaned — deals.vehicle_id and deal_products.product_id both NULL, so
# the inventory report can't find the deal on the home.
#
# Match strategy (matches against non-deleted vehicles in the same company):
#   1. Exact match on normalized "year make model"
#   2. Fallback: product_name starts with normalized "year make model"
# Anything with 0 or 2+ matches is REPORTED, never written — no ambiguity risk.
#
# DRY-RUN by default. Set APPLY=1 to write. COMPANY_ID=<id> to scope.
#
#   bin/rails deals:backfill_vehicle_links                 # dry-run, all companies
#   COMPANY_ID=17 bin/rails deals:backfill_vehicle_links   # dry-run, company 17
#   COMPANY_ID=17 APPLY=1 bin/rails deals:backfill_vehicle_links   # write, company 17
namespace :deals do
  desc "Backfill deals.vehicle_id + deal_products.product_id for orphaned home line items. DRY-RUN by default; APPLY=1 to write; COMPANY_ID=<id> to scope."
  task backfill_vehicle_links: :environment do
    apply      = ENV['APPLY'] == '1'
    company_id = ENV['COMPANY_ID'].presence

    mode = apply ? 'APPLY' : 'DRY-RUN'
    puts "[deals:backfill_vehicle_links] mode=#{mode} company_id=#{company_id || 'ALL'}"

    normalize = ->(s) { s.to_s.downcase.gsub(/\s+/, ' ').strip }

    # Candidate deals: no vehicle_id, has at least one home-flavored line item.
    # source_type='home' is the modern discriminator; also match legacy items
    # whose 'category:home' note was set before source_type was in use.
    candidate_deal_ids = DealProduct
      .joins(:deal)
      .where(deals: { vehicle_id: nil, deleted_at: nil })
      .where("deal_products.source_type = 'home' OR deal_products.notes ILIKE '%category:home%'")
      .distinct
      .pluck('deals.id')

    scope = Deal.where(id: candidate_deal_ids)
    scope = scope.where(company_id: company_id) if company_id

    stats = { deals_scanned: 0, linked: 0, no_match: 0, ambiguous: 0, no_home_line: 0 }
    ambiguous_report = []
    no_match_report  = []

    scope.includes(:company, :deal_products).find_each do |deal|
      stats[:deals_scanned] += 1
      company = deal.company
      next unless company

      home_lines = deal.deal_products.select do |dp|
        dp.source_type.to_s == 'home' || dp.notes.to_s.downcase.include?('category:home')
      end
      if home_lines.empty?
        stats[:no_home_line] += 1
        next
      end

      # Vehicles pool for this company. Cached per-company inside the loop to
      # avoid re-querying for tenants with many deals; simple memoize keyed on
      # company_id keeps the task lightweight.
      @vehicles_by_company ||= {}
      vehicles = @vehicles_by_company[company.id] ||= company.vehicles
                                                             .where(is_deleted: [false, nil])
                                                             .select(:id, :year, :make, :model)
                                                             .to_a

      # Match each home line to a vehicle. Every distinct home line must land
      # on the same vehicle for us to auto-link; otherwise the deal is left
      # for manual review (someone linked two homes to one deal).
      matches_per_line = home_lines.map do |dp|
        target = normalize.call(dp.product_name)
        next [] if target.empty?

        # Exact "year make model"
        exact = vehicles.select { |v| normalize.call("#{v.year} #{v.make} #{v.model}") == target }
        next exact if exact.any?

        # Fallback: product_name starts with "year make model" (extra text after)
        vehicles.select do |v|
          combo = normalize.call("#{v.year} #{v.make} #{v.model}")
          combo.length >= 5 && target.start_with?(combo)
        end
      end

      distinct_matches = matches_per_line.map { |ms| ms.map(&:id) }.reject(&:empty?).uniq

      if distinct_matches.empty?
        stats[:no_match] += 1
        no_match_report << { deal_id: deal.id, deal_number: deal.deal_number, names: home_lines.map(&:product_name) }
        next
      end

      if distinct_matches.size > 1
        stats[:ambiguous] += 1
        ambiguous_report << { deal_id: deal.id, deal_number: deal.deal_number, candidates: distinct_matches.flatten.uniq }
        next
      end

      match_ids = distinct_matches.first
      if match_ids.size > 1
        stats[:ambiguous] += 1
        ambiguous_report << { deal_id: deal.id, deal_number: deal.deal_number, candidates: match_ids }
        next
      end

      vehicle_id = match_ids.first
      if apply
        Deal.transaction do
          deal.update_columns(vehicle_id: vehicle_id, updated_at: Time.current)
          home_lines.each do |dp|
            dp.update_columns(product_id: vehicle_id, updated_at: Time.current) if dp.product_id.blank?
          end
        end
      end
      stats[:linked] += 1
    end

    puts ''
    puts "Scanned:       #{stats[:deals_scanned]}"
    puts "Linked:        #{stats[:linked]}#{apply ? '' : ' (would link)'}"
    puts "No match:      #{stats[:no_match]}"
    puts "Ambiguous:     #{stats[:ambiguous]}"
    puts "No home line:  #{stats[:no_home_line]}"

    if no_match_report.any?
      puts ''
      puts '--- No match (product_name did not resolve to any vehicle) ---'
      no_match_report.first(50).each do |r|
        puts "  Deal ##{r[:deal_id]} #{r[:deal_number]}: #{r[:names].join(' | ')}"
      end
      puts "  ... and #{no_match_report.size - 50} more" if no_match_report.size > 50
    end

    if ambiguous_report.any?
      puts ''
      puts '--- Ambiguous (multiple vehicle candidates) ---'
      ambiguous_report.first(50).each do |r|
        puts "  Deal ##{r[:deal_id]} #{r[:deal_number]}: candidates=#{r[:candidates].inspect}"
      end
      puts "  ... and #{ambiguous_report.size - 50} more" if ambiguous_report.size > 50
    end

    puts ''
    puts apply ? 'DONE (writes applied).' : 'DRY-RUN complete. Re-run with APPLY=1 to write.'
  end
end
