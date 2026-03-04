class Api::V1::ManufacturersController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/manufacturers
  # Returns manufacturers that have active floor plans
  def index
    manufacturer_ids = FloorPlan
      .where(is_active: true)
      .distinct
      .pluck(:manufacturer_id)
      .compact

    manufacturers = Manufacturer
      .where(id: manufacturer_ids)
      .order(:name)

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
