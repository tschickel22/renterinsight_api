# frozen_string_literal: true

# The zoning choices a dealer's land parcels pick from, kept per company
# (Company Settings, Customize, Land Zoning).
#
#   GET  /api/v1/company/land-zoning       { options: [{value, label}], defaults: [...] }
#   PUT  /api/v1/company/land-zoning       { options: [{value?, label}] }  company_settings:update
#   POST /api/v1/company/land-zoning/add   { label }                       inventory create or update
#
# Anyone who can add or edit land can add a new choice from the land form;
# removing or reordering choices is a company setting.
class Api::V1::LandZoningOptionsController < ApplicationController
  before_action :set_company_scope

  def show
    render json: payload
  end

  def update
    return unless authorize_action!('company_settings', 'update')

    LandParcel.save_zoning_options(@company, Array(params[:options]).map { |o| o.respond_to?(:to_unsafe_h) ? o.to_unsafe_h : o })
    render json: payload
  end

  def add
    unless can?('inventory', 'create') || can?('inventory', 'update')
      return render json: { error: 'You do not have permission to add zoning types' }, status: :forbidden
    end

    label = params[:label].to_s.squish.first(LandParcel::ZONING_MAX_LENGTH)
    return render(json: { error: 'Type a zoning name' }, status: :unprocessable_entity) if label.blank?

    option = LandParcel.add_zoning_option(@company, label)
    render json: payload.merge(added: option)
  end

  private

  def payload
    { options: LandParcel.zoning_options_for(@company), defaults: LandParcel.default_zoning_options }
  end
end
