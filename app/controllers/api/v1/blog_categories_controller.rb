class Api::V1::BlogCategoriesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website
  before_action :set_category, only: [:show, :update, :destroy]

  # GET /api/v1/websites/:website_id/blog/categories
  def index
    return unless authorize_action!('websites', 'read')

    categories = @website.blog_categories.where(is_deleted: [false, nil])

    # Apply search filter
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      categories = categories.where(
        "name ILIKE ? OR slug ILIKE ? OR description ILIKE ?",
        search_term, search_term, search_term
      )
    end

    # Sort by order, then name
    sort_by = params[:sort_by] || 'order'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    categories = categories.order(sort_by => sort_order, :name)

    render json: categories.as_json(methods: [:posts_count])
  end

  # GET /api/v1/websites/:website_id/blog/categories/:id
  def show
    return unless authorize_action!('websites', 'read')

    render json: @category.as_json(
      methods: [:posts_count],
      include: {
        blog_posts: {
          only: [:id, :title, :slug, :status, :published_at],
          methods: [:reading_time]
        }
      }
    )
  end

  # POST /api/v1/websites/:website_id/blog/categories
  def create
    return unless authorize_action!('websites', 'create')

    # CRITICAL: Use @website scope - sets website_id automatically
    category = @website.blog_categories.build(category_params)

    # Auto-set order if not provided
    if category.order.nil?
      max_order = @website.blog_categories.maximum(:order) || 0
      category.order = max_order + 1
    end

    if category.save
      render json: category, status: :created
    else
      render json: { errors: category.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/websites/:website_id/blog/categories/:id
  def update
    return unless authorize_action!('websites', 'update')

    if @category.update(category_params)
      render json: @category
    else
      render json: { errors: @category.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/websites/:website_id/blog/categories/:id
  def destroy
    return unless authorize_action!('websites', 'delete')

    # Check if category has posts
    if @category.blog_posts.any?
      render json: { 
        error: "Cannot delete category with #{@category.blog_posts.count} blog posts. Please reassign or delete posts first." 
      }, status: :unprocessable_entity
      return
    end

    @category.update!(is_deleted: true, deleted_at: Time.current)
    head :no_content
  end

  # POST /api/v1/websites/:website_id/blog/categories/bulk_reorder
  def bulk_reorder
    return unless authorize_action!('websites', 'update')

    category_orders = params[:category_orders] || []

    ActiveRecord::Base.transaction do
      category_orders.each do |item|
        category = @website.blog_categories.find(item[:id])
        category.update!(order: item[:order])
      end
    end

    render json: { message: 'Categories reordered successfully' }
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

  def set_category
    # CRITICAL: Nested scope - category must belong to this website
    @category = @website.blog_categories.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Category not found' }, status: :not_found
  end

  def category_params
    # CRITICAL: NEVER permit website_id - set via @website.blog_categories.build()
    params.require(:blog_category).permit(
      :name,
      :slug,
      :description,
      :order,
      :seo_title,
      :seo_description
    )
  end
end
