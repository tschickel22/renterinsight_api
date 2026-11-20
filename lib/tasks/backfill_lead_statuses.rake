# frozen_string_literal: true
namespace :crm do
  desc 'Create missing default lead statuses for companies that have none (APPLY=1 to write)'
  task backfill_lead_statuses: :environment do
    apply = ENV['APPLY'].present?
    scope = ENV['COMPANY_ID'].present? ? Company.where(id: ENV['COMPANY_ID']) : Company.all
    created_total = 0
    touched = 0
    scope.order(:id).each do |company|
      n = if apply
            LeadStatus.ensure_for(company)
          else
            would = 0
            ActiveRecord::Base.transaction do
              would = LeadStatus.ensure_for(company)
              raise ActiveRecord::Rollback
            end
            would
          end
      next if n.zero?
      touched += 1
      created_total += n
      have = LeadStatus.where(company_id: company.id).count
      label = "#{company.id} #{company.account_number} #{company.name}"
      puts apply ? "  #{label}: created #{n}" : "  #{label}: has #{have}, would create #{n}"
    end
    if touched.zero?
      puts 'every company already has its default lead statuses'
    elsif apply
      puts "companies touched=#{touched} statuses created=#{created_total}"
    else
      puts "#{touched} companies would get #{created_total} statuses"
      puts 'MODE: dry run (pass APPLY=1 to write)'
    end
  end
end
