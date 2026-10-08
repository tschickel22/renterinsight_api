# frozen_string_literal: true

# The company's Deal Sheets (the LIVE version of each deal's home build), for
# pickers such as the PO form's: a home order is written from a Deal Sheet.
#
#   GET /api/v1/deal_sheets?search=&per_page=
class Api::V1::DealSheetsController < ApplicationController
  include ModuleAccessRequired
  require_module! Truebuild::BuyerCatalog::MODULE
  before_action :set_company_scope

  def index
    return unless authorize_action!('deals', 'read')

    deals = @company.deals
    if current_user.uses_rbac? && !current_user.effective_admin?
      ids = permission_service.accessible_location_ids
      deals = ids.any? ? deals.where(location_id: ids) : deals.none
    end
    builds = @company.deal_home_builds.where(live: true, deal_id: deals.select(:id))
                     .includes(:deal, variant: %i[catalog_plan manufacturer]).order(updated_at: :desc)
    if params[:search].present?
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
      builds = builds.joins(:deal).left_joins(deal: :contact)
                     .where('deals.name ILIKE :q OR deals.deal_number ILIKE :q OR contacts.first_name ILIKE :q OR contacts.last_name ILIKE :q', q: q)
    end
    ordered = PurchaseOrder.where(deal_id: builds.map(&:deal_id), kind: 'factory_home', is_deleted: [false, nil]).group(:deal_id).count
    per_page = [(params[:per_page] || 200).to_i, 500].min
    render json: { deal_sheets: builds.limit(per_page).map { |b|
      d = b.deal
      v = b.variant
      { deal_id: d.id, deal_number: d.deal_number, deal_name: d.name, buyer: d.customer_display_name,
        model: "#{v.catalog_plan.name} (#{v.model_number})", manufacturer: v.manufacturer&.name, source: b.source,
        version_name: b.version_name, ordered: ordered[d.id].to_i.positive? }
    } }
  end
end
