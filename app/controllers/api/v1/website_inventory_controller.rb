# frozen_string_literal: true

# Edit Website, Inventory tab (2026-11-11): the site's "Show asking prices"
# switch, the rules that hide brands, series, models or statuses from it, and
# single homes switched off. Hidden homes stay in inventory; only this site's
# public inventory leaves them out (Websites::InventorySettings).
#
#   GET /api/v1/websites/:website_id/inventory_settings   settings, rule choices, counts
#   PUT /api/v1/websites/:website_id/inventory_settings   { inventory_settings: { show_prices, hide_rules, hidden_vehicle_ids, release_price_list } }
#   GET /api/v1/websites/:website_id/inventory_homes      ?search=&page=&per_page=
class Api::V1::WebsiteInventoryController < ApplicationController
  before_action :set_company_scope
  before_action :set_website

  def show
    return unless authorize_action!('websites', 'read')

    render json: settings_json
  end

  def update
    return unless authorize_action!('websites', 'update')

    raw = params.require(:inventory_settings)
    current = Websites::InventorySettings.new(@website)
    incoming = Websites::InventorySettings.normalize(raw.permit(:show_prices, hidden_vehicle_ids: [], hide_rules: %i[field value]),
                                                     company: @company)

    stored = {
      'show_prices' => incoming.key?('show_prices') ? incoming['show_prices'] : current.show_prices?,
      'hide_rules' => raw.key?(:hide_rules) ? incoming['hide_rules'] : current.rules,
      'hidden_vehicle_ids' => raw.key?(:hidden_vehicle_ids) ? incoming['hidden_vehicle_ids'] : current.hidden_ids
    }
    # A site from before the switch keeps price list prices hidden until the
    # dealer turns the switch on themselves or asks for them to show.
    release = ActiveModel::Type::Boolean.new.cast(raw[:release_price_list]) == true ||
              stored['show_prices'] != current.show_prices?
    stored['price_list_held'] = true if current.price_list_held? && !release
    stored['featured_price_held'] = true if current.featured_price_held? && !release

    @website.update!(inventory_settings: stored.deep_stringify_keys)
    render json: settings_json
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def homes
    return unless authorize_action!('websites', 'read')

    list = Websites::InventoryHomes.new(@website)
    render json: list.page(search: params[:search], page: params[:page] || 1,
                           per_page: params[:per_page] || Websites::InventoryHomes::PER_PAGE)
                     .tap { |body| body[:meta].merge!(list.counts) }
  end

  private

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.where(is_deleted: [false, nil]).find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def settings_json
    @website.reload
    settings = Websites::InventorySettings.new(@website)
    list = Websites::InventoryHomes.new(@website, settings: settings)
    {
      settings: settings.to_h,
      options: list.options,
      counts: list.counts,
      featured_in_use: @website.featured_homes.where(show_sale: true).exists?
    }
  end
end
