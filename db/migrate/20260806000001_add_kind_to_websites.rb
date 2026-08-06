# frozen_string_literal: true

# Distinguishes a dealer's real website from the system-owned container that
# holds landing pages.
#
# Landing pages are WebsitePages, which means they need a Website to hang off.
# A dealer buying only the landing page module has no website with us at all, so
# one is provisioned for them (Marketing::MarketingSiteProvisioner). That
# container must never appear in the websites list or the site editor — it is
# infrastructure, not a product surface — and `kind` is what lets every read
# path tell the two apart.
class AddKindToWebsites < ActiveRecord::Migration[8.0]
  def up
    add_column :websites, :kind, :string, default: 'site', null: false
    add_index :websites, :kind

    # Existing rows are all real dealer sites. The column default covers new
    # rows; this covers the ones already there, explicitly rather than relying
    # on the default having been applied during the add_column backfill.
    execute("UPDATE websites SET kind = 'site' WHERE kind IS NULL")
  end

  def down
    remove_index :websites, :kind
    remove_column :websites, :kind
  end
end
