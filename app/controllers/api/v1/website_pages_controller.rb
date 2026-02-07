class Api::V1::WebsitePagesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website
  before_action :set_page, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('websites', 'read')

    @pages = @website.site_pages.where(is_deleted: [false, nil]).order(:order)
    render json: @pages
  end

  def show
    return unless authorize_action!('websites', 'read')
    render json: @page
  end

  def create
    return unless authorize_action!('websites', 'create')

    @page = @website.site_pages.build(page_params)

    if @page.save
      render json: @page, status: :created
    else
      render json: { errors: @page.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('websites', 'update')

    if @page.update(page_params)
      render json: @page
    else
      render json: { errors: @page.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('websites', 'delete')

    @page.update!(is_deleted: true)
    head :no_content
  end

  def reorder
    return unless authorize_action!('websites', 'update')

    orders = params[:orders] || []
    
    orders.each do |order_data|
      page = @website.site_pages.find_by(id: order_data[:id])
      page.update(order: order_data[:order]) if page
    end

    render json: { message: 'Pages reordered successfully' }
  end

  private

  def set_website
    @website = @company.sites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def set_page
    @page = @website.site_pages.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Page not found' }, status: :not_found
  end

  def page_params
    params.require(:page).permit(
      :title,
      :path,
      :order,
      :is_visible,
      :seo_title,
      :seo_description,
      :og_image_url,
      blocks: []
    )
  end
end
