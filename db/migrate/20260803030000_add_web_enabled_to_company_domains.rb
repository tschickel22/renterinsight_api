# frozen_string_literal: true

# Marks whether a domain is used for website hosting, mirroring email_enabled.
#
# Without it the two capabilities are indistinguishable after creation: "purpose" was only
# ever a create-time parameter, never persisted. So a domain added purely for sending email
# appeared in the website list as permanently "DNS Verification Pending", because nothing
# had verified it and nothing ever would.
class AddWebEnabledToCompanyDomains < ActiveRecord::Migration[8.0]
  def up
    add_column :company_domains, :web_enabled, :boolean, default: false, null: false

    # Anything already provisioned with Cloudflare is a website domain by definition.
    execute(<<~SQL.squish)
      UPDATE company_domains
      SET web_enabled = true
      WHERE cloudflare_custom_hostname_id IS NOT NULL
         OR website_id IS NOT NULL
    SQL
  end

  def down
    remove_column :company_domains, :web_enabled
  end
end
