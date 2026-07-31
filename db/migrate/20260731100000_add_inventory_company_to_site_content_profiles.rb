# frozen_string_literal: true

# Which lot a demo shows must be chosen, not inherited.
#
# Previously a profile's inventory came from profile.company — whichever tenant
# the admin happened to be switched to when they created it — so a prospect's
# public preview could display a real customer's live inventory to a third
# party. The choice is now explicit, and defaults to the nominated demo lot.
class AddInventoryCompanyToSiteContentProfiles < ActiveRecord::Migration[8.0]
  def change
    add_reference :site_content_profiles, :inventory_company,
                  foreign_key: { to_table: :companies }, null: true
  end
end
