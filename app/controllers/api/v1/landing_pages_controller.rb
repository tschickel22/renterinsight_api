# frozen_string_literal: true

# Landing pages.
#
# A landing page is a WebsitePage with page_kind 'landing', living on the
# company's system-owned marketing container (Marketing::MarketingSiteProvisioner)
# unless it was put on a real site deliberately. That means domains, DNS, SSL,
# host resolution, SSR head tags, robots and sitemap are all inherited from the
# website builder — none of it is reimplemented here.
#
# Separate from WebsitePagesController because the surfaces differ completely:
# that one edits a page inside a site tree (nav, ordering, parents), this one
# manages standalone conversion pages (publish state, campaign linkage, forms,
# cloning).
class Api::V1::LandingPagesController < ApplicationController
  before_action :set_company_scope
  before_action :set_page,
                only: %i[show update destroy publish unpublish duplicate clone_to_locations analytics visitors]

  def index
    return unless authorize_action!('websites', 'read')

    pages = company_landing_pages.includes(:campaign, :intake_form)
    pages = pages.where(campaign_id: params[:campaign_id]) if params[:campaign_id].present?

    if params[:status].present?
      pages = params[:status] == 'published' ? pages.published : pages.where(published_at: nil)
    end

    if params[:search].present?
      pages = pages.where('title ILIKE :q OR path ILIKE :q', q: "%#{params[:search]}%")
    end

    render json: {
      items: pages.order(updated_at: :desc).limit(200).map { |p| summary(p) },
      meta: { stats: stats }
    }
  end

  def show
    return unless authorize_action!('websites', 'read')

    render json: detail(@page)
  end

  # Creates the marketing container on first use, so a dealer who has never
  # built a website can still publish a landing page.
  def create
    return unless authorize_action!('websites', 'create')

    site = Marketing::MarketingSiteProvisioner.call(company: @company, location: target_location)

    page = site.website_pages.new(page_params)
    page.page_kind = 'landing'
    page.site_content_profile_id = params[:site_content_profile_id].presence
    page.layout_id = params[:layout_id].presence
    page.campaign_id = params[:campaign_id].presence

    if page.save
      render json: detail(page), status: :created
    else
      render json: { error: page.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue Marketing::MarketingSiteProvisioner::ProvisioningError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    return unless authorize_action!('websites', 'update')

    if @page.update(page_params)
      render json: detail(@page)
    else
      render json: { error: @page.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('websites', 'delete')

    @page.update!(is_deleted: true, deleted_at: Time.current, published_at: nil, is_visible: false)
    head :no_content
  end

  # Page-level, not site-level. The marketing container is always published —
  # Websites::HostResolver only resolves published sites — so this is what
  # actually decides whether a visitor can reach the page.
  def publish
    return unless authorize_action!('websites', 'update')

    @page.publish!
    render json: detail(@page)
  end

  def unpublish
    return unless authorize_action!('websites', 'update')

    @page.unpublish!
    render json: detail(@page)
  end

  # POST /api/v1/landing_pages/:id/duplicate
  def duplicate
    return unless authorize_action!('websites', 'create')

    copy = Marketing::LandingPageDuplicator.new(
      @page,
      user: current_user,
      title: params[:title].presence,
      campaign_id: params[:campaign_id].presence,
      share_form: ActiveModel::Type::Boolean.new.cast(params[:share_form])
    ).call

    render json: detail(copy), status: :created
  rescue Marketing::LandingPageDuplicator::DuplicationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/landing_pages/:id/clone_to_locations
  #
  # Copy stays identical; only location-bound data varies. Deterministic, so no
  # AI call and no credit consumption regardless of how many locations.
  def clone_to_locations
    return unless authorize_action!('websites', 'create')

    locations = @company.locations.active.where(id: Array(params[:location_ids]))
    if locations.empty?
      return render json: { error: 'Select at least one location.' }, status: :unprocessable_entity
    end

    result = Marketing::LandingPageLocationCloner.new(
      @page,
      user: current_user,
      locations: locations,
      share_form: ActiveModel::Type::Boolean.new.cast(params[:share_form])
    ).call

    render json: {
      items: result.pages.map { |p| summary(p) },
      cloned_count: result.cloned_count,
      # Reported rather than rolled back: one rooftop failing should not cost
      # the others.
      failures: result.failures
    }, status: :created
  end

  # GET /api/v1/landing_pages/:id/analytics
  def analytics
    return unless authorize_action!('websites', 'read')

    render json: Marketing::LandingPageAnalytics.new(
      @page,
      from: params[:from].presence && Time.zone.parse(params[:from]),
      to: params[:to].presence && Time.zone.parse(params[:to])
    ).call
  end

  # GET /api/v1/landing_pages/:id/visitors
  #
  # Identified visitors only. An anonymous row has nothing a salesperson can
  # act on, and listing them would turn a work surface into a log file.
  def visitors
    return unless authorize_action!('websites', 'read')

    visits = PageVisit.real
                      .where(website_page_id: @page.id)
                      .identified
                      .order(last_seen_at: :desc)
                      .limit(200)

    render json: {
      items: visits.map do |visit|
        {
          id: visit.id,
          entity_type: visit.identified_entity_type,
          entity_id: visit.identified_entity_id,
          entity_name: visit.identified_entity.try(:full_name) ||
                       visit.identified_entity.try(:name),
          first_seen_at: visit.first_seen_at,
          last_seen_at: visit.last_seen_at,
          max_scroll_depth: visit.max_scroll_depth,
          duration_ms: visit.duration_ms,
          converted: visit.converted,
          campaign_id: visit.campaign_id,
          utm_source: visit.utm_source,
          device_type: visit.device_type
        }
      end
    }
  end

  private

  # Landing pages live on any of the company's websites — normally the
  # marketing container, but a page deliberately placed on the dealer's real
  # site is still theirs. Scoped through the company either way.
  def company_landing_pages
    WebsitePage.active.landing_pages.where(website_id: @company.websites.select(:id))
  end

  def set_page
    @page = company_landing_pages.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Landing page not found' }, status: :not_found
  end

  def target_location
    return nil if params[:location_id].blank?

    @company.locations.active.find_by(id: params[:location_id])
  end

  def page_params
    params.permit(
      :title, :path, :is_visible, :seo_title, :seo_description, :og_image_url,
      :robots, :canonical_path, :intake_form_id, :layout_id,
      style: {},
      blocks: [:id, :type, :order, { content: {}, settings: {} }]
    )
  end

  def stats
    scope = company_landing_pages
    {
      total: scope.count,
      published: scope.published.count,
      draft: scope.where(published_at: nil).count
    }
  end

  def summary(page)
    {
      id: page.id,
      website_id: page.website_id,
      title: page.title,
      path: page.path,
      page_kind: page.page_kind,
      layout_id: page.layout_id,
      published: page.published?,
      published_at: page.published_at,
      robots: page.robots,
      campaign_id: page.campaign_id,
      intake_form_id: page.intake_form_id,
      site_content_profile_id: page.site_content_profile_id,
      public_url: public_url_for(page),
      updated_at: page.updated_at,
      created_at: page.created_at
    }
  end

  def detail(page)
    summary(page).merge(
      blocks: page.blocks,
      style: page.style,
      seo_title: page.seo_title,
      seo_description: page.seo_description,
      og_image_url: page.og_image_url,
      canonical_path: page.canonical_path
    )
  end

  # Built from the same resolution order Websites::HostResolver uses, so what
  # the builder shows is what a visitor would actually type.
  def public_url_for(page)
    site = page.website
    return nil if site.nil?

    host = site.company_domains.detect(&:web_enabled?)&.hostname
    host ||= site.domain.presence
    host ||= "#{site.subdomain}.#{Brand.current.subdomain_root}" if site.subdomain.present?
    return nil if host.blank?

    "https://#{host}#{page.path}"
  end
end
