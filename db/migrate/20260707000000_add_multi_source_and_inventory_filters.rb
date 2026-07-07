class AddMultiSourceAndInventoryFilters < ActiveRecord::Migration[8.0]
  # Three additions to support "leads + contacts tagged weekly-favorites"
  # newsletter campaigns and admin-controlled inventory selection:
  #
  # 1. campaign_audiences.additional_source_types (jsonb, default [])
  #    Enroller loops this after the primary source_type so one campaign
  #    can fan out to Lead + Contact + Account. Existing single-source
  #    campaigns leave this empty and behave identically.
  #
  # 2. nurture_steps.inventory_statuses (jsonb, default [])
  #    nurture_steps.inventory_require_images (bool, default false)
  #    Empty statuses = today's baked-in ['available', 'available_to_order'].
  #    require_images = today's behavior (no filter). Both opt-in.
  def change
    add_column :campaign_audiences, :additional_source_types, :jsonb, default: [], null: false

    add_column :nurture_steps, :inventory_statuses, :jsonb, default: [], null: false
    add_column :nurture_steps, :inventory_require_images, :boolean, default: false, null: false
  end
end
