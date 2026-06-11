namespace :import do
  desc 'Reconcile pending import links for a company (back-fill deferred associations). ' \
       'Usage: rake import:reconcile_links COMPANY_ID=15  -- idempotent, safe to re-run.'
  task reconcile_links: :environment do
    company_id = ENV['COMPANY_ID']
    if company_id.blank?
      puts 'COMPANY_ID is required. Example: rake import:reconcile_links COMPANY_ID=15'
      next
    end

    company = Company.find_by(id: company_id)
    unless company
      puts "Company #{company_id} not found."
      next
    end

    pending_before = PendingImportLink.pending.where(company_id: company.id).count
    if pending_before.zero?
      puts "Company #{company.id} (#{company.name}): no pending import links. Nothing to do."
      next
    end

    puts "Reconciling #{pending_before} pending link(s) for Company #{company.id} (#{company.name})..."

    resolver = ImportExport::LinkResolver.new(company)
    resolved = resolver.reconcile_all!

    pending_after = PendingImportLink.pending.where(company_id: company.id).count

    puts ''
    puts 'Reconciliation complete.'
    puts "  Foreign keys back-filled: #{resolved}"
    puts "  Still pending (parent not yet imported): #{pending_after}"

    if pending_after.positive?
      puts ''
      puts '  Outstanding by parent model:'
      PendingImportLink.pending
                       .where(company_id: company.id)
                       .group(:parent_model)
                       .count
                       .each { |model, n| puts "    #{model}: #{n}" }
    end
  end

  desc 'Show a summary of pending import links for a company. ' \
       'Usage: rake import:pending_links COMPANY_ID=15'
  task pending_links: :environment do
    company_id = ENV['COMPANY_ID']
    if company_id.blank?
      puts 'COMPANY_ID is required. Example: rake import:pending_links COMPANY_ID=15'
      next
    end

    scope = PendingImportLink.pending.where(company_id: company_id)
    total = scope.count
    puts "Pending import links for Company #{company_id}: #{total}"
    next if total.zero?

    puts ''
    puts 'By parent model:'
    scope.group(:parent_model).count.each { |model, n| puts "  #{model}: #{n}" }

    puts ''
    puts 'By waiting child type:'
    scope.group(:entity_type).count.each { |type, n| puts "  #{type}: #{n}" }
  end
end
