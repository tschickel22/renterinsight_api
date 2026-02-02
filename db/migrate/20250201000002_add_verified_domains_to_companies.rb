# frozen_string_literal: true

class AddVerifiedDomainsToCompanies < ActiveRecord::Migration[8.0]
  def change
    # Add verified_domains array to companies
    # This allows auto-trusting user emails that match company domains
    # Example: If company verifies "acme.com", users with @acme.com emails are auto-trusted
    add_column :companies, :verified_email_domains, :jsonb, default: []
    add_index :companies, :verified_email_domains, using: :gin, name: 'idx_companies_verified_domains'
  end
end
