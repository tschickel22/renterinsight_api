# frozen_string_literal: true

# Companies created before public inventory existed never got a token or its
# defaults (Company#generate_public_inventory_token and
# #set_default_public_inventory_settings run on create only). Production had
# four, Summit Park among them: a published website's inventory block loads
# homes with the token, so it showed nothing, and show_pricing unset would
# have hidden every price.
#
# Gives each one a token and fills in only the defaults it is missing; a
# setting already made, including one switched off, stays as it is.
class BackfillPublicInventoryDefaults < ActiveRecord::Migration[8.0]
  class Co < ActiveRecord::Base
    self.table_name = 'companies'
  end

  DEFAULTS = {
    'public_inventory_enabled' => true, 'public_statuses' => %w[available available_to_order], 'show_pricing' => true,
    'show_contact_button' => true, 'contact_button_text' => 'Request Info', 'require_approval' => false,
    'items_per_page' => 12, 'default_layout' => 'grid', 'show_filters' => true
  }.freeze

  def up
    Co.where(public_inventory_token: nil).find_each do |c|
      token = loop do
        candidate = SecureRandom.urlsafe_base64(32)
        break candidate unless Co.exists?(public_inventory_token: candidate)
      end
      c.update_columns(public_inventory_token: token)
    end
    Co.find_each do |c|
      settings = c.public_inventory_settings.is_a?(Hash) ? c.public_inventory_settings : {}
      merged = DEFAULTS.merge(settings)
      c.update_columns(public_inventory_settings: merged) if merged != settings
    end
  end

  def down; end
end
