class Api::V1::WebsitePagesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website
  before_action :set_page, only: [:show, :update, :destroy, :show_page, :hide_page, :reorder]

  # GET /api/v1/websites/:website_id/pages
  def index
    return unless authorize_action!('websites', 'read')

    pages = @website.website_pages.where(is_deleted: [false, nil])

    # Apply search filter
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      pages = pages.where("title ILIKE ? OR path ILIKE ?", search_term, search_term)
    end

    # Filter by visibility
    pages = pages.where(is_visible: params[:is_visible]) if params[:is_visible].present?

    # COMMENTED OUT - parent_page_id column doesn't exist yet
    # # Filter by parent (top-level pages or children)
    # if params[:parent_id].present?
    #   pages = pages.where(parent_page_id: params[:parent_id])
    # elsif params[:top_level] == 'true'
    #   pages = pages.where(parent_page_id: nil)
    # end

    # Sort by order, then title
    pages = pages.order(:order, :title)

    # COMMENTED OUT - parent_page and child_pages associations don't exist yet
    # render json: pages.as_json(
    #   include: {
    #     parent_page: { only: [:id, :title, :path] },
    #     child_pages: { only: [:id, :title, :path, :order] }
    #   }
    # )
    
    render json: { items: pages.as_json }
  end

  # GET /api/v1/websites/:website_id/pages/:id
  def show
    return unless authorize_action!('websites', 'read')

    # COMMENTED OUT - parent_page and child_pages associations don't exist yet
    # render json: @page.as_json(
    #   include: {
    #     parent_page: { only: [:id, :title, :path] },
    #     child_pages: { only: [:id, :title, :path, :order, :is_visible] }
    #   }
    # )
    
    render json: @page.as_json
  end

  # POST /api/v1/websites/:website_id/pages
  def create
    return unless authorize_action!('websites', 'create')

    # CRITICAL: Use @website scope - sets website_id automatically
    page = @website.website_pages.build(page_params)

    # Auto-set order if not provided (append to end)
    if page.order.nil?
      max_order = @website.website_pages.maximum(:order) || 0
      page.order = max_order + 1
    end

    if page.save
      render json: page, status: :created
    else
      render json: { errors: page.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/websites/:website_id/pages/:id
  def update
    return unless authorize_action!('websites', 'update')

    if @page.update(page_params)
      render json: @page
    else
      render json: { errors: @page.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/websites/:website_id/pages/:id
  def destroy
    return unless authorize_action!('websites', 'delete')

    @page.update!(is_deleted: true)
    head :no_content
  end

  # POST /api/v1/websites/:website_id/pages/:id/show
  def show_page
    return unless authorize_action!('websites', 'update')

    if @page.show!
      render json: { message: 'Page is now visible', page: @page }
    else
      render json: { errors: @page.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/websites/:website_id/pages/:id/hide
  def hide_page
    return unless authorize_action!('websites', 'update')

    if @page.hide!
      render json: { message: 'Page is now hidden', page: @page }
    else
      render json: { errors: @page.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/websites/:website_id/pages/:id/reorder
  def reorder
    return unless authorize_action!('websites', 'update')

    new_order = params[:new_order].to_i

    if @page.update(order: new_order)
      render json: { message: 'Page reordered successfully', page: @page }
    else
      render json: { errors: @page.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/websites/:website_id/pages/bulk_reorder
  def bulk_reorder
    return unless authorize_action!('websites', 'update')

    page_orders = params[:page_orders] || []

    ActiveRecord::Base.transaction do
      page_orders.each do |item|
        page = @website.website_pages.find(item[:id])
        page.update!(order: item[:order])
      end
    end

    render json: { message: 'Pages reordered successfully' }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.message }, status: :unprocessable_entity
  end

  private

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def set_page
    # CRITICAL: Nested scope - page must belong to this website
    @page = @website.website_pages.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Page not found' }, status: :not_found
  end

  def page_params
    # CRITICAL: NEVER permit website_id - set via @website.website_pages.build()
    params.require(:website_page).permit(
      :title,
      :path,
      :order,
      :is_visible,
      :show_in_nav,
      :show_in_footer,
      :parent_page_id,  # Will be ignored if column doesn't exist
      :seo_title,
      :seo_description,
      :og_image_url,
      :robots,
      :canonical_path,
      style: {},  # Permit page-level style settings (backgroundColor, backgroundImage, etc.)
      blocks: [
        :id,
        :type,
        :order,
        content: {},  # Permit any content hash (JSONB flexibility)
        spacing: {},
        borders: {},
        shadows: {},
        filters: {}
      ]
    )
  end
end
