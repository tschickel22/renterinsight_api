class Api::V1::BlogPostsController < ApplicationController
  before_action :set_company_scope
  before_action :set_website
  before_action :set_blog_post, only: [:show, :update, :destroy, :publish, :unpublish, :schedule, :increment_views]

  # GET /api/v1/websites/:website_id/blog/posts
  def index
    return unless authorize_action!('websites', 'read')

    posts = @website.blog_posts.where(is_deleted: [false, nil])

    # Apply search filter
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      posts = posts.where(
        "title ILIKE ? OR slug ILIKE ? OR excerpt ILIKE ? OR content ILIKE ?",
        search_term, search_term, search_term, search_term
      )
    end

    # Filter by status
    posts = posts.where(status: params[:status]) if params[:status].present?

    # Filter by category
    if params[:category_id].present?
      posts = posts.joins(:blog_categories).where(blog_categories: { id: params[:category_id] })
    end

    # Filter by author
    posts = posts.where(author_id: params[:author_id]) if params[:author_id].present?

    # Count stats BEFORE pagination (for tiles)
    all_posts_count = posts.count
    status_counts = {
      draft: posts.where(status: BlogPost.statuses[:draft]).count,
      published: posts.where(status: BlogPost.statuses[:published]).count,
      scheduled: posts.where(status: BlogPost.statuses[:scheduled]).count
    }

    # Sort
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    posts = posts.order(sort_by => sort_order)

    # Paginate
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 50).to_i
    per_page = [per_page, 200].min
    
    filtered_count = posts.count
    posts = posts.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: posts.as_json(
        include: {
          author: { only: [:id, :first_name, :last_name, :email] },
          blog_categories: { only: [:id, :name, :slug] }
        },
        methods: [:reading_time]
      ),
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: status_counts.merge(total: all_posts_count)
      }
    }
  end

  # GET /api/v1/websites/:website_id/blog/posts/:id
  def show
    return unless authorize_action!('websites', 'read')

    render json: @blog_post.as_json(
      include: {
        author: { only: [:id, :first_name, :last_name, :email] },
        blog_categories: { only: [:id, :name, :slug] }
      },
      methods: [:reading_time]
    )
  end

  # POST /api/v1/websites/:website_id/blog/posts
  def create
    return unless authorize_action!('websites', 'create')

    # CRITICAL: Use @website scope - sets website_id automatically
    post = @website.blog_posts.build(blog_post_params)

    # Set author to current user if not specified
    post.author_id ||= current_user.id

    if post.save
      # Handle category associations
      if params[:category_ids].present?
        category_ids = params[:category_ids].select(&:present?)
        post.blog_category_ids = category_ids
      end

      render json: post.as_json(
        include: {
          author: { only: [:id, :first_name, :last_name, :email] },
          blog_categories: { only: [:id, :name, :slug] }
        }
      ), status: :created
    else
      render json: { errors: post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/websites/:website_id/blog/posts/:id
  def update
    return unless authorize_action!('websites', 'update')

    if @blog_post.update(blog_post_params)
      # Handle category associations
      if params[:category_ids].present?
        category_ids = params[:category_ids].select(&:present?)
        @blog_post.blog_category_ids = category_ids
      end

      render json: @blog_post.as_json(
        include: {
          author: { only: [:id, :first_name, :last_name, :email] },
          blog_categories: { only: [:id, :name, :slug] }
        }
      )
    else
      render json: { errors: @blog_post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/websites/:website_id/blog/posts/:id
  def destroy
    return unless authorize_action!('websites', 'delete')

    @blog_post.update!(is_deleted: true, deleted_at: Time.current)
    head :no_content
  end

  # POST /api/v1/websites/:website_id/blog/posts/:id/publish
  def publish
    return unless authorize_action!('websites', 'update')

    if @blog_post.publish!
      render json: { message: 'Blog post published successfully', blog_post: @blog_post }
    else
      render json: { errors: @blog_post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/websites/:website_id/blog/posts/:id/unpublish
  def unpublish
    return unless authorize_action!('websites', 'update')

    if @blog_post.unpublish!
      render json: { message: 'Blog post unpublished successfully', blog_post: @blog_post }
    else
      render json: { errors: @blog_post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/websites/:website_id/blog/posts/:id/schedule
  def schedule
    return unless authorize_action!('websites', 'update')

    scheduled_at = params[:scheduled_at]

    if scheduled_at.blank?
      render json: { error: 'scheduled_at is required' }, status: :unprocessable_entity
      return
    end

    if @blog_post.schedule!(scheduled_at)
      render json: { message: 'Blog post scheduled successfully', blog_post: @blog_post }
    else
      render json: { errors: @blog_post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/websites/:website_id/blog/posts/:id/increment_views
  def increment_views
    # No authorization needed - public endpoint
    @blog_post.increment_views!
    render json: { view_count: @blog_post.view_count }
  end

  private

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def set_blog_post
    # CRITICAL: Nested scope - post must belong to this website
    @blog_post = @website.blog_posts.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Blog post not found' }, status: :not_found
  end

  def blog_post_params
    # CRITICAL: NEVER permit website_id or author_id in params
    # website_id set via @website.blog_posts.build()
    # author_id set explicitly in create/update actions
    params.require(:blog_post).permit(
      :title,
      :slug,
      :excerpt,
      :content,
      :featured_image_url,
      :featured_image_alt,
      :status,
      :published_at,
      :scheduled_at,
      :seo_title,
      :seo_description,
      :og_image_url,
      :robots
    )
  end
end
