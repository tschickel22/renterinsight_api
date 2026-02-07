class Api::V1::BlogPostsController < ApplicationController
  before_action :set_company_scope
  before_action :set_website
  before_action :set_post, only: [:show, :update, :destroy, :publish, :unpublish]

  def index
    return unless authorize_action!('websites', 'read')

    @posts = @website.blog_posts.where(is_deleted: [false, nil])

    # Filter by status if provided
    if params[:status].present?
      @posts = @posts.where(status: params[:status])
    end

    # Filter by category if provided
    if params[:category_id].present?
      @posts = @posts.joins(:blog_categories).where(blog_categories: { id: params[:category_id] })
    end

    @posts = @posts.order(created_at: :desc)

    render json: @posts.as_json(
      include: {
        author: { only: [:id, :first_name, :last_name, :email] },
        blog_categories: { only: [:id, :name, :slug] }
      }
    )
  end

  def show
    return unless authorize_action!('websites', 'read')
    
    # Increment view count (unless author viewing own post)
    unless @post.author_id == current_user.id
      @post.increment_views!
    end
    
    render json: @post.as_json(
      include: {
        author: { only: [:id, :first_name, :last_name, :email] },
        blog_categories: { only: [:id, :name, :slug] }
      }
    )
  end

  def create
    return unless authorize_action!('websites', 'create')

    @post = @website.blog_posts.build(post_params)
    @post.author = current_user

    # Assign categories if provided
    if params[:category_ids].present?
      categories = @website.blog_categories.where(id: params[:category_ids])
      @post.blog_categories = categories
    end

    if @post.save
      render json: @post.as_json(
        include: {
          author: { only: [:id, :first_name, :last_name, :email] },
          blog_categories: { only: [:id, :name, :slug] }
        }
      ), status: :created
    else
      render json: { errors: @post.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('websites', 'update')

    # Update categories if provided
    if params[:category_ids].present?
      categories = @website.blog_categories.where(id: params[:category_ids])
      @post.blog_categories = categories
    end

    if @post.update(post_params)
      render json: @post.as_json(
        include: {
          author: { only: [:id, :first_name, :last_name, :email] },
          blog_categories: { only: [:id, :name, :slug] }
        }
      )
    else
      render json: { errors: @post.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('websites', 'delete')

    @post.update!(is_deleted: true)
    head :no_content
  end

  def publish
    return unless authorize_action!('websites', 'update')

    @post.publish!

    render json: {
      message: 'Blog post published successfully',
      post: @post,
      published_at: @post.published_at
    }
  end

  def unpublish
    return unless authorize_action!('websites', 'update')

    @post.unpublish!

    render json: {
      message: 'Blog post unpublished successfully',
      post: @post
    }
  end

  private

  def set_website
    @website = @company.sites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def set_post
    @post = @website.blog_posts.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Blog post not found' }, status: :not_found
  end

  def post_params
    params.require(:blog_post).permit(
      :title,
      :slug,
      :excerpt,
      :content,
      :featured_image_url,
      :status,
      :scheduled_at,
      :seo_title,
      :seo_description,
      :og_image_url
    )
  end
end
