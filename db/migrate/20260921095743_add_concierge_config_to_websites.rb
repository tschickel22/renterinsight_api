# frozen_string_literal: true

# The chat assistant had no off switch and no name of its own: it appeared on
# every site and landing page of any company that had the module, captioned
# with the website's internal name ("DealerTide App Landing Pages").
class AddConciergeConfigToWebsites < ActiveRecord::Migration[8.0]
  def change
    add_column :websites, :concierge_config, :jsonb, default: {}, null: false
  end
end
