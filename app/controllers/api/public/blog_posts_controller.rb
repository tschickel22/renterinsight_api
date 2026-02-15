# Public Blog Controller - No authentication required
# Used by the public site renderer to display blog posts
class Api::Public::BlogPostsController < ApplicationController
  skip_before_action :authenticate
  
  # GET /api/public/websites/:token/blog
  # Returns published blog posts for a website (for blogList block)
  def index
    @website = Website.find_by!(preview_token: params[:token])
    
    posts = @website.blog_posts
                    .where(is_deleted: [false, nil])
                    .where(status: :published)
                    .where('published_at <= ?', Time.current)
                    .order(published_at: :desc)
    
    # Filter by category slug
    if params[:category].present?
      posts = posts.joins(:blog_categories)
                   .where(blog_categories: { slug: params[:category] })
    end
    
    # Search
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      posts = posts.where("title ILIKE ? OR excerpt ILIKE ?", search_term, search_term)
    end
    
    # Pagination
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 12).to_i
    per_page = [per_page, 50].min
    
    total = posts.count
    posts = posts.offset((page - 1) * per_page).limit(per_page)
    
    render json: {
      posts: posts.as_json(
        only: [:id, :title, :slug, :excerpt, :featured_image_url, :featured_image_alt, 
               :published_at, :view_count, :status],
        include: {
          author: { only: [:id, :first_name, :last_name] },
          blog_categories: { only: [:id, :name, :slug] }
        },
        methods: [:reading_time]
      ),
      meta: {
        total: total,
        page: page,
        per_page: per_page,
        total_pages: (total.to_f / per_page).ceil
      }
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end
  
  # GET /api/public/websites/:token/blog/:slug
  # Returns a single published blog post by slug
  def show
    @website = Website.find_by!(preview_token: params[:token])
    
    post = @website.blog_posts
                   .where(is_deleted: [false, nil])
                   .where(status: :published)
                   .where('published_at <= ?', Time.current)
                   .find_by!(slug: params[:slug])
    
    # Increment view count
    post.increment!(:view_count)
    
    # Get related posts (same categories, exclude current)
    category_ids = post.blog_category_ids
    related_posts = if category_ids.any?
      @website.blog_posts
              .joins(:blog_categories)
              .where(blog_categories: { id: category_ids })
              .where(is_deleted: [false, nil])
              .where(status: :published)
              .where('published_at <= ?', Time.current)
              .where.not(id: post.id)
              .distinct
              .order(published_at: :desc)
              .limit(3)
    else
      @website.blog_posts
              .where(is_deleted: [false, nil])
              .where(status: :published)
              .where('published_at <= ?', Time.current)
              .where.not(id: post.id)
              .order(published_at: :desc)
              .limit(3)
    end
    
    render json: {
      post: post.as_json(
        only: [:id, :title, :slug, :excerpt, :content, :featured_image_url, :featured_image_alt,
               :published_at, :view_count, :seo_title, :seo_description, :og_image_url],
        include: {
          author: { only: [:id, :first_name, :last_name] },
          blog_categories: { only: [:id, :name, :slug] }
        },
        methods: [:reading_time]
      ),
      related_posts: related_posts.as_json(
        only: [:id, :title, :slug, :excerpt, :featured_image_url, :featured_image_alt, :published_at],
        include: {
          author: { only: [:id, :first_name, :last_name] },
          blog_categories: { only: [:id, :name, :slug] }
        },
        methods: [:reading_time]
      )
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Blog post not found' }, status: :not_found
  end
  
  # GET /api/public/websites/:token/blog/categories
  # Returns categories with post counts
  def categories
    @website = Website.find_by!(preview_token: params[:token])
    
    categories = @website.blog_categories
                         .where(is_deleted: [false, nil])
                         .order(:order, :name)
    
    render json: categories.as_json(
      only: [:id, :name, :slug, :description],
      methods: [:posts_count]
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end
end
