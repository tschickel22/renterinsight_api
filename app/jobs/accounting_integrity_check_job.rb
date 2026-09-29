# frozen_string_literal: true

# Nightly read-only check of every company with accounting activity; emails
# the platform (support address) when any company's books need attention, so
# we hear about it before a customer does. Scheduled in config/recurring.yml;
# `rake accounting:integrity_check` runs it on demand.
class AccountingIntegrityCheckJob < ApplicationJob
  queue_as :default

  # Returns the per-company results that had issues.
  def perform
    company_ids = JournalEntry.distinct.pluck(:company_id)
    results = Company.where(id: company_ids).find_each.filter_map { |company| check(company) }

    AccountingIntegrityMailer.issues_found(results).deliver_now if results.any?
    Rails.logger.info("[AccountingIntegrity] #{results.size} of #{company_ids.size} companies need attention")
    results
  end

  private

  def check(company)
    issues = Accounting::IntegrityCheckService.new(company).issues
    return if issues.empty?

    {
      company_id: company.id,
      company_name: company.name,
      account_number: company.try(:account_number),
      issues: issues.map { |i| { severity: i.severity, message: i.message } }
    }
  rescue StandardError => e
    Rails.logger.error("[AccountingIntegrity] #{company.name} (id #{company.id}) check failed: #{e.class}: #{e.message}")
    {
      company_id: company.id,
      company_name: company.name,
      account_number: company.try(:account_number),
      issues: [{ severity: :error, message: "Check could not run: #{e.class}: #{e.message.to_s.first(160)}" }]
    }
  end
end
