# frozen_string_literal: true

# Lets a CompanyDomain carry an SES sending identity alongside its web hosting role, so a
# tenant manages one record per hostname instead of the platform keeping three unrelated
# half-built domain systems (companies.custom_domain, companies.email_domain, and this).
class AddEmailSendingToCompanyDomains < ActiveRecord::Migration[8.0]
  def change
    change_table :company_domains, bulk: true do |t|
      t.boolean  :email_enabled, default: false, null: false
      t.string   :ses_identity_status
      t.jsonb    :ses_dkim_tokens, default: []
      t.string   :ses_mail_from_domain
      t.string   :ses_mail_from_status
      t.datetime :email_verified_at
      t.datetime :ses_checked_at
      t.string   :ses_error
    end

    # Resolving an outbound from-address to a sending identity happens on every campaign
    # send, keyed by the domain part of the address.
    add_index :company_domains,
              %i[company_id hostname],
              where: 'email_enabled = true',
              name: 'idx_company_domains_email_sending'

    # The status poller sweeps identities that are enabled but not yet verified.
    add_index :company_domains,
              :ses_checked_at,
              where: 'email_enabled = true AND email_verified_at IS NULL',
              name: 'idx_company_domains_ses_pending'
  end
end
