class Api::V1::ManufacturersController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/manufacturers(?industry_type=)
  # Platform manufacturers and this company's own. This used to list only
  # manufacturers with an active floor plan in the retired configurator,
  # which were none, so the warranty claim and AR payment pickers were empty.
  def index
    manufacturers = Manufacturer.visible_to_company(@company.id)
    manufacturers = manufacturers.where(industry_type: params[:industry_type]) if params[:industry_type].present?
    manufacturers = manufacturers.order(:name)

    render json: {
      items: manufacturers.map { |m| { id: m.id, name: m.name } }
    }
  end

  # GET /api/v1/manufacturers/:id
  def show
    manufacturer = Manufacturer.find(params[:id])
    render json: { id: manufacturer.id, name: manufacturer.name }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # GET /api/v1/manufacturers/:id/parts
  def parts
    manufacturer = Manufacturer.find(params[:id])
    parts = @company.parts.where(manufacturer_name: manufacturer.name, is_deleted: [false, nil])
    render json: parts
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # GET /api/v1/manufacturers/stats
  def stats
    render json: { total: Manufacturer.count }
  end

  # GET /api/v1/manufacturers/autocomplete
  def autocomplete
    query = params[:query].to_s
    manufacturers = Manufacturer.where('name ILIKE ?', "%#{query}%").order(:name).limit(20)
    render json: { suggestions: manufacturers.map(&:name) }
  end
end
