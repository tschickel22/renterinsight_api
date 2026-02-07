class Api::V1::WebsitesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website, only: [:show, :update, :destroy, :publish, :unpublish]

  def index
    return unless authorize_action!('websites', 'read')

    @websites = @company.sites.where(is_deleted: [false, nil])

    # RBAC location filtering
    if current_user.uses_rbac?
      unless current_user.effective_admin?
        location_ids = permission_service.accessible_location_ids
        @websites = location_ids.any? ? 
          @websites.where(location_id: location_ids) : 
          @websites.none
      end
    end

    # Location selector filter
    @websites = @websites.for_current_location

    render json: @websites
  end

  def show
    return unless authorize_action!('websites', 'read')
    
    render json: @website.as_json(
      include: {
        site_pages: { only: [:id, :title, :path, :order, :is_visible] },
        blog_categories: { only: [:id, :name, :slug] }
      }
    )
  end

  def create
    return unless authorize_action!('websites', 'create')

    @website = @company.sites.build(website_params)

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
      render json: { errors: @website.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('websites', 'update')

    if @website.update(website_params)
      render json: @website
    else
      render json: { errors: @website.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('websites', 'delete')

    @website.update!(is_deleted: true)
    head :no_content
  end

  def publish
    return unless authorize_action!('websites', 'update')

    # Create version snapshot
    @website.create_version!(
      version_name: "Published #{Time.current.strftime('%Y-%m-%d %H:%M')}",
      created_by: current_user
    )

    # Update status to published
    @website.publish!

    # TODO: Deploy to Netlify (Phase 6-7)
    # For now, return demo/production URLs
    render json: {
      message: 'Website published successfully',
      demo_url: @website.demo_url,
      production_url: @website.production_url,
      published_at: @website.published_at
    }
  end

  def unpublish
    return unless authorize_action!('websites', 'update')

    @website.unpublish!

    render json: {
      message: 'Website unpublished successfully',
      status: @website.status
    }
  end

  private

  def set_website
    @website = @company.sites.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def website_params
    params.require(:website).permit(
      :name,
      :slug,
      :domain,
      :subdomain,
      :status,
      :build_status,
      :client_access_level,
      :location_id,
      :favicon_url,
      theme: {},
      nav_config: {},
      brand: {},
      seo_config: {},
      tracking_config: {}
    )
    # CRITICAL: NEVER permit company_id
  end
end
