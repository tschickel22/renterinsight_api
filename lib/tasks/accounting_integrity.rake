# frozen_string_literal: true

namespace :accounting do
  desc 'Check every company with accounting activity; email the platform if any books need attention (read-only)'
  task integrity_check: :environment do
    company_ids = JournalEntry.distinct.pluck(:company_id)
    results = Company.where(id: company_ids).find_each.filter_map do |company|
      issues = Accounting::IntegrityCheckService.new(company).issues
      label = "#{company.name} (id #{company.id})"
      if issues.empty?
        puts "OK      #{label}"
        next
      end

      puts "ISSUES  #{label}"
      issues.each { |i| puts "          [#{i.severity}] #{i.message}" }
      {
        company_id: company.id,
        company_name: company.name,
        account_number: company.try(:account_number),
        issues: issues.map { |i| { severity: i.severity, message: i.message } }
      }
    rescue StandardError => e
      puts "FAILED  #{company.name} (id #{company.id}): #{e.class}: #{e.message}"
      nil
    end

    AccountingIntegrityMailer.issues_found(results).deliver_now if results.any?
    puts "#{results.size} of #{company_ids.size} companies need attention"
  end
end
