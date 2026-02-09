# API V1 Websites Controller
# Handles CRUD operations for websites

class Api::V1::WebsitesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website, only: [:show, :update, :destroy, :publish, :unpublish, :sync_branding]

  def index
    # CRITICAL: Authorization FIRST
    return unless authorize_action!('websites', 'read')

    # Base query with tenant isolation
    @websites = @company.websites.where(is_deleted: [false, nil])

    # RBAC + Location filtering
    if current_user.uses_rbac?
      if current_user.effective_admin?
        # Company-tier admins see all
      else
        location_ids = permission_service.accessible_location_ids
        @websites = location_ids.any? ? 
          @websites.where(location_id: location_ids) : 
          @websites.none
      end
    end

    # Apply location selector filter
    if Current.location_filtered?
      @websites = @websites.where(location_id: Current.location_id)
    end

    # Apply status filter
    @websites = @websites.where(status: params[:status]) if params[:status].present?

    # Count stats BEFORE search (stats tiles show ALL websites)
    all_count = @websites.count
    status_counts = {
      published: @websites.where(status: 'published').count,
      draft: @websites.where(status: 'draft').count,
      unpublished: @websites.where(status: 'unpublished').count,
      this_month: @websites.where('created_at >= ?', Date.today.beginning_of_month).count
    }

    # Apply search filter
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @websites = @websites.where(
        "name ILIKE ? OR slug ILIKE ? OR domain ILIKE ? OR subdomain ILIKE ?",
        search_term, search_term, search_term, search_term
      )
    end

    # Apply sorting
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    @websites = @websites.order(sort_by => sort_order)

    # Count AFTER search (for pagination)
    filtered_count = @websites.count

    # Paginate
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 50).to_i
    per_page = [per_page, 200].min
    @websites = @websites.offset((page - 1) * per_page).limit(per_page)

    # Return with dual meta
    render json: {
      items: @websites.as_json(
        include: {
          website_pages: { only: [:id, :title, :slug, :is_visible] },
          blog_posts: { only: [:id, :title, :slug, :status] }
        }
      ),
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: status_counts.merge(total: all_count)
      }
    }
  end

  def show
    return unless authorize_action!('websites', 'read')
    
    render json: @website.as_json(
      include: {
        website_pages: { only: [:id, :title, :slug, :is_visible, :page_order] },
        blog_posts: { only: [:id, :title, :slug, :status, :published_at] }
      }
    )
  end

  def create
    return unless authorize_action!('websites', 'create')

    @website = @company.websites.build(website_params)
    
    # Auto-assign location_id
    @website.location_id ||= Current.location_id if Current.location_id.present?
    
    # RBAC fallback for location-tier users
    if @website.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      @website.location_id = location_ids.first if location_ids.any?
    end

    if @website.save
      render json: @website, status: :created
    else
      render json: { errors: @website.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('websites', 'update')

    if @website.update(website_params)
      render json: @website
    else
      render json: { errors: @website.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/websites/:id
  def destroy
    return unless authorize_action!('websites', 'delete')
    
    @website.update(is_deleted: true)
    head :no_content
  end

  # POST /api/v1/websites/:id/publish
  def publish
    return unless authorize_action!('websites', 'update')

    @website.update(status: 'published', published_at: Time.current)
    render json: @website
  end

  # POST /api/v1/websites/:id/unpublish
  def unpublish
    return unless authorize_action!('websites', 'update')

    @website.update(status: 'unpublished')
    render json: @website
  end

  # POST /api/v1/websites/:id/sync_branding
  # Sync branding from Company or Location settings
  def sync_branding
    return unless authorize_action!('websites', 'update')
    
    source_type = params[:source_type] # 'company' or 'location'
    location_id = params[:location_id]
    
    branding_data = case source_type
    when 'location'
      if location_id.blank?
        return render json: { error: 'location_id required when source_type is location' }, status: :bad_request
      end
      
      location = @company.locations.find_by(id: location_id)
      unless location
        return render json: { error: 'Location not found' }, status: :not_found
      end
      
      extract_location_branding(location)
    when 'company'
      extract_company_branding(@company)
    else
      return render json: { error: 'Invalid source_type. Must be company or location' }, status: :bad_request
    end
    
    # Merge synced branding into website's existing data
    @website.theme = (@website.theme || {}).merge(branding_data[:theme])
    @website.brand = (@website.brand || {}).merge(branding_data[:brand])
    @website.nav_config = (@website.nav_config || {}).merge(branding_data[:nav_config])
    
    if @website.save
      render json: {
        website: @website,
        synced_from: source_type,
        synced_fields: branding_data.keys
      }
    else
      render json: { errors: @website.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # GET /api/v1/websites/stats
  def stats
    return unless authorize_action!('websites', 'read')

    base_websites = @company.websites.where(is_deleted: [false, nil])
    base_websites = base_websites.where(location_id: Current.location_id) if Current.location_filtered?

    render json: {
      total: base_websites.count,
      published: base_websites.where(status: 'published').count,
      draft: base_websites.where(status: 'draft').count,
      unpublished: base_websites.where(status: 'unpublished').count,
      this_month: base_websites.where('created_at >= ?', Date.today.beginning_of_month).count
    }
  end
  
  # GET /api/v1/websites/branding_preview
  # Preview branding from Company or Location before syncing
  def branding_preview
    return unless authorize_action!('websites', 'read')
    
    source_type = params[:source_type]
    location_id = params[:location_id]
    
    branding_data = case source_type
    when 'location'
      if location_id.blank?
        return render json: { error: 'location_id required' }, status: :bad_request
      end
      
      location = @company.locations.find_by(id: location_id)
      unless location
        return render json: { error: 'Location not found' }, status: :not_found
      end
      
      extract_location_branding(location)
    when 'company'
      extract_company_branding(@company)
    else
      return render json: { error: 'Invalid source_type' }, status: :bad_request
    end
    
    render json: branding_data
  end

  private

  def set_website
    # ALWAYS use scoped find - tenant isolation
    @website = @company.websites.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end
  
  # Extract branding from Location settings
  def extract_location_branding(location)
    resolved_branding = location.resolved_branding_settings || {}
    
    {
      theme: {
        primary_color: resolved_branding['primary_color'] || resolved_branding['primaryColor'],
        secondary_color: resolved_branding['secondary_color'] || resolved_branding['secondaryColor'],
        font_family: resolved_branding['font_family'] || resolved_branding['fontFamily'] || 'Inter'
      },
      brand: {
        company_name: location.company.name,
        logo_url: resolved_branding['logo'] || resolved_branding['logo_url'],
        phone: location.phone,
        email: location.email,
        address: location.address_line1,
        city: location.city,
        state: location.state,
        zip: location.zip_code,
        country: location.country || 'US'
      },
      nav_config: {
        logo_position: 'left',
        layout: 'horizontal',
        sticky: true
      }
    }
  end
  
  # Extract branding from Company settings
  def extract_company_branding(company)
    # Company-level branding (if stored in platform_settings or similar)
    # For now, use sensible defaults with company name
    {
      theme: {
        primary_color: '#3b82f6',
        secondary_color: '#8b5cf6',
        font_family: 'Inter'
      },
      brand: {
        company_name: company.name
      },
      nav_config: {
        logo_position: 'left',
        layout: 'horizontal',
        sticky: true
      }
    }
  end

  def website_params
    params.require(:website).permit(
      :name,
      :slug,
      :domain,
      :subdomain,
      :location_id,
      :status,
      :build_status,
      :client_access_level,
      :preview_url,
      :live_url,
      :favicon_url,
      :netlify_site_id,
      :cloudflare_zone_id,
      :published_at,
      theme: [
        :name,
        :primary_color,
        :secondary_color,
        :accent_color,
        :font_family,
        :heading_font,
        :custom_css
      ],
      nav_config: [
        :logo_position,
        :layout,
        :sticky,
        items: [:label, :url, :target, :order, :parent_id]
      ],
      brand: [
        :company_name,
        :tagline,
        :description,
        :logo_url,
        :favicon_url,
        :phone,
        :email,
        :address,
        :city,
        :state,
        :zip,
        :country,
        social_media: [:facebook, :twitter, :instagram, :linkedin, :youtube]
      ],
      seo_config: [
        :default_title,
        :default_description,
        :og_title,
        :og_description,
        :og_image_url,
        :twitter_card,
        :twitter_site,
        :google_site_verification,
        :bing_site_verification,
        keywords: []
      ],
      tracking_config: [
        :google_analytics_id,
        :google_tag_manager_id,
        :facebook_pixel_id,
        :hotjar_id,
        :custom_scripts
      ]
    )
    # CRITICAL: NEVER permit company_id
  end
end
