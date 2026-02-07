class Api::V1::BlogCategoriesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website
  before_action :set_category, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('websites', 'read')

    @categories = @website.blog_categories.where(is_deleted: [false, nil])

    render json: @categories.map { |category|
      category.as_json.merge(posts_count: category.posts_count)
    }
  end

  def show
    return unless authorize_action!('websites', 'read')
    
    render json: @category.as_json.merge(posts_count: @category.posts_count)
  end

  def create
    return unless authorize_action!('websites', 'create')

    @category = @website.blog_categories.build(category_params)

    if @category.save
      render json: @category.as_json.merge(posts_count: 0), status: :created
    else
      render json: { errors: @category.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('websites', 'update')

    if @category.update(category_params)
      render json: @category.as_json.merge(posts_count: @category.posts_count)
    else
      render json: { errors: @category.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('websites', 'delete')

    @category.update!(is_deleted: true)
    head :no_content
  end

  private

  def set_website
    @website = @company.sites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def set_category
    @category = @website.blog_categories.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Category not found' }, status: :not_found
  end

  def category_params
    params.require(:blog_category).permit(
      :name,
      :slug,
      :description
    )
  end
end
