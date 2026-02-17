class UpdatePublicStatusesToIncludeAvailableToOrder < ActiveRecord::Migration[8.0]
  def up
    # Update all existing companies to include 'available_to_order' in their public_statuses
    # Uses raw SQL to avoid dependency on model store_accessor configuration
    execute <<-SQL
      UPDATE companies
      SET public_inventory_settings = jsonb_set(
        COALESCE(public_inventory_settings, '{}'),
        '{public_statuses}',
        CASE
          WHEN public_inventory_settings->'public_statuses' IS NULL
            THEN '["available", "available_to_order"]'::jsonb
          WHEN NOT (public_inventory_settings->'public_statuses' @> '"available_to_order"')
            THEN (public_inventory_settings->'public_statuses') || '"available_to_order"'::jsonb
          ELSE public_inventory_settings->'public_statuses'
        END
      )
    SQL
  end

  def down
    # Remove 'available_to_order' from all companies' public_statuses
    execute <<-SQL
      UPDATE companies
      SET public_inventory_settings = jsonb_set(
        COALESCE(public_inventory_settings, '{}'),
        '{public_statuses}',
        COALESCE(
          (public_inventory_settings->'public_statuses') - 'available_to_order',
          '[]'::jsonb
        )
      )
      WHERE public_inventory_settings->'public_statuses' @> '"available_to_order"'
    SQL
  end
end
