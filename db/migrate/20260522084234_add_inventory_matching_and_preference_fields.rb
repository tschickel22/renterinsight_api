# frozen_string_literal: true

class AddInventoryMatchingAndPreferenceFields < ActiveRecord::Migration[8.0]
  def change
    # ---- tracked_links: vehicle_id, link_type, url ----
    unless column_exists?(:tracked_links, :vehicle_id)
      add_column :tracked_links, :vehicle_id, :bigint
    end

    unless column_exists?(:tracked_links, :link_type)
      add_column :tracked_links, :link_type, :string, default: 'attachment'
    end

    unless column_exists?(:tracked_links, :url)
      add_column :tracked_links, :url, :string
    end

    # s3_key was previously NOT NULL because tracked links only carried S3
    # attachments. Inventory tracked links use the url column instead, so
    # s3_key needs to allow NULL.
    s3_col = columns(:tracked_links).find { |c| c.name == 's3_key' }
    if s3_col && !s3_col.null
      change_column_null :tracked_links, :s3_key, true
    end

    add_index :tracked_links, :vehicle_id, if_not_exists: true
    add_index :tracked_links,
              [:entity_type, :entity_id, :vehicle_id],
              name: 'idx_tracked_links_entity_vehicle',
              if_not_exists: true

    # ---- nurture_steps: include_inventory, inventory_display_mode ----
    unless column_exists?(:nurture_steps, :include_inventory)
      add_column :nurture_steps, :include_inventory, :boolean, default: false
    end

    unless column_exists?(:nurture_steps, :inventory_display_mode)
      add_column :nurture_steps, :inventory_display_mode, :string, default: 'auto'
    end

    # ---- leads: preference fields (budget_range + vehicle_id already exist) ----
    unless column_exists?(:leads, :preferred_bedrooms)
      add_column :leads, :preferred_bedrooms, :integer
    end

    unless column_exists?(:leads, :preferred_bathrooms)
      add_column :leads, :preferred_bathrooms, :integer
    end

    unless column_exists?(:leads, :preferred_min_sqft)
      add_column :leads, :preferred_min_sqft, :integer
    end

    unless column_exists?(:leads, :preferred_max_sqft)
      add_column :leads, :preferred_max_sqft, :integer
    end

    unless column_exists?(:leads, :preferred_home_type)
      add_column :leads, :preferred_home_type, :string
    end

    # ---- contacts: preference fields (all new) ----
    unless column_exists?(:contacts, :preferred_bedrooms)
      add_column :contacts, :preferred_bedrooms, :integer
    end

    unless column_exists?(:contacts, :preferred_bathrooms)
      add_column :contacts, :preferred_bathrooms, :integer
    end

    unless column_exists?(:contacts, :preferred_min_sqft)
      add_column :contacts, :preferred_min_sqft, :integer
    end

    unless column_exists?(:contacts, :preferred_max_sqft)
      add_column :contacts, :preferred_max_sqft, :integer
    end

    unless column_exists?(:contacts, :preferred_home_type)
      add_column :contacts, :preferred_home_type, :string
    end

    unless column_exists?(:contacts, :preferred_vehicle_id)
      add_column :contacts, :preferred_vehicle_id, :bigint
    end

    unless column_exists?(:contacts, :budget_range)
      add_column :contacts, :budget_range, :string
    end

    add_index :contacts, :preferred_vehicle_id, if_not_exists: true
  end
end
