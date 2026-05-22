class BackfillPublicInventoryForAllCompanies < ActiveRecord::Migration[8.0]
  # Backfills public_inventory_token (column) and public_inventory_enabled
  # (stored in public_inventory_settings JSONB via store_accessor) for all
  # existing companies, so nurture email inventory links work out of the box.
  def up
    # 1. Backfill missing tokens
    Company.where(public_inventory_token: [nil, '']).find_each do |company|
      token = loop do
        candidate = SecureRandom.urlsafe_base64(32)
        break candidate unless Company.exists?(public_inventory_token: candidate)
      end
      company.update_columns(public_inventory_token: token)
    end

    # 2. Enable public inventory for every company by setting the JSONB key.
    #    public_inventory_enabled is a store_accessor on public_inventory_settings,
    #    so we update the JSONB directly with a single SQL statement.
    execute(<<~SQL)
      UPDATE companies
      SET public_inventory_settings =
        COALESCE(public_inventory_settings, '{}'::jsonb)
        || jsonb_build_object('public_inventory_enabled', true)
      WHERE (public_inventory_settings->>'public_inventory_enabled') IS DISTINCT FROM 'true'
    SQL
  end

  def down
    # No rollback — tokens should persist and public inventory should stay enabled.
  end
end
