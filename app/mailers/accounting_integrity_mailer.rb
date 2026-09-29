# frozen_string_literal: true

# Tells the platform which companies' books need attention, before a
# customer finds out their numbers don't tie out. System-facing, so it uses
# the platform brand (see BRAND KERNEL in CLAUDE.md).
class AccountingIntegrityMailer < ApplicationMailer
  # results: [{ company_id:, company_name:, account_number:, issues: [{ severity:, message: }] }]
  def issues_found(results)
    @results = results
    @brand   = Brand.current

    mail(
      to: @brand.support_email,
      from: default_from_address,
      subject: "Accounting check: #{results.size} #{'company'.pluralize(results.size)} " \
               "#{results.size == 1 ? 'needs' : 'need'} attention"
    )
  end
end
