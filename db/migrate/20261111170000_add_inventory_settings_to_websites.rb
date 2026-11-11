# frozen_string_literal: true

# Edit Website, Inventory tab: one "Show asking prices" switch per site, rules
# that hide brands, series, models or statuses, and single hidden homes.
#
# Additive only (two-release safe): the running code never reads the column.
#
# Each existing site starts with what it shows today:
#   show_prices      on when any Inventory section on the site showed prices
#                    (its own "Show pricing on cards", unset following the
#                    company's Show pricing); with no Inventory section, a
#                    Featured Homes section with "Show price" on; with
#                    neither, the company's Show pricing.
#   price_list_held  on a site that shows prices while the company's Show
#                    pricing is off or TrueBuild "What buyers see" is not
#                    full or starting at: price list prices and the TrueBuild
#                    design page keep following those settings, as before,
#                    until the dealer saves the switch. So nothing a live
#                    site shows changes.
#   featured_price_held  on a site that shows prices whose Featured Homes
#                    sections had "Show price" off (the default): those cards
#                    keep showing no price until the dealer saves the switch.
#
# Self-contained on purpose: models change, this must not.
class AddInventorySettingsToWebsites < ActiveRecord::Migration[8.0]
  class MWebsite < ActiveRecord::Base
    self.table_name = 'websites'
  end

  INVENTORY = %w[inventory].freeze
  FEATURED = %w[featuredHomes featured_homes].freeze

  def up
    add_column :websites, :inventory_settings, :jsonb, default: {}, null: false
    MWebsite.reset_column_information

    MWebsite.where(is_deleted: [false, nil]).find_each do |site|
      company = select_one("SELECT public_inventory_settings FROM companies WHERE id = #{site.company_id.to_i}")
      co_settings = parse(company && company['public_inventory_settings'])
      company_on = co_settings['show_pricing'] != false && co_settings['show_pricing'].to_s != 'false'
      display = select_value("SELECT price_display FROM dealer_catalog_terms WHERE company_id = #{site.company_id.to_i} " \
                             'AND manufacturer_id IS NULL ORDER BY id LIMIT 1') || 'hidden'

      inventory = []
      featured = []
      select_values("SELECT blocks FROM website_pages WHERE website_id = #{site.id.to_i} AND COALESCE(is_deleted, false) = false")
        .each { |raw| collect(parse_any(raw), inventory, featured) }

      show = if inventory.any?
               inventory.any? do |c|
                 own = c.key?('show_pricing') ? c['show_pricing'] : c['showPricing']
                 own.nil? ? company_on : own != false && own.to_s != 'false'
               end
             elsif featured.any?
               featured.any? { |c| c['showPricing'] == true }
             else
               company_on
             end

      settings = { 'show_prices' => show, 'hide_rules' => [], 'hidden_vehicle_ids' => [] }
      settings['price_list_held'] = true if show && (!company_on || !%w[full starting_at].include?(display))
      settings['featured_price_held'] = true if show && featured.any? && featured.none? { |c| c['showPricing'] == true }
      site.update_columns(inventory_settings: settings)
    end
  end

  def down
    remove_column :websites, :inventory_settings
  end

  private

  def collect(node, inventory, featured)
    case node
    when Array
      node.each { |child| collect(child, inventory, featured) }
    when Hash
      type = node['type'].to_s
      content = node['content'].is_a?(Hash) ? node['content'] : node
      inventory << content if INVENTORY.include?(type)
      featured << content if FEATURED.include?(type)
      node.each_value { |child| collect(child, inventory, featured) if child.is_a?(Array) || child.is_a?(Hash) }
    end
  end

  def parse(raw)
    value = parse_any(raw)
    value.is_a?(Hash) ? value : {}
  end

  def parse_any(raw)
    raw.is_a?(String) ? JSON.parse(raw) : raw
  rescue JSON::ParserError
    nil
  end
end
