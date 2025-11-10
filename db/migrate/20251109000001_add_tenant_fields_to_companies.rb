# frozen_string_literal: true

class AddTenantFieldsToCompanies < ActiveRecord::Migration[8.0]
  def change
    # Subdomain for tenant isolation
    add_column :companies, :subdomain, :string
    add_index :companies, :subdomain, unique: true

    # Custom domain support
    add_column :companies, :custom_domain, :string
    add_column :companies, :domain_verified_at, :datetime
    add_column :companies, :domain_verification_token, :string
    add_index :companies, :custom_domain

    # Email domain for custom sending addresses
    add_column :companies, :email_domain, :string
    add_column :companies, :email_domain_verified_at, :datetime

    # Tenant status and subscription
    add_column :companies, :status, :string, default: 'active'
    add_column :companies, :trial_ends_at, :datetime
    add_column :companies, :subscription_tier, :string
    add_column :companies, :max_users, :integer
    add_column :companies, :max_storage_gb, :integer

    # Zoho billing integration
    add_column :companies, :zoho_subscription_id, :string
    add_column :companies, :zoho_customer_id, :string

    # Add indexes for performance
    add_index :companies, :status
    add_index :companies, :subscription_tier
  end
end
