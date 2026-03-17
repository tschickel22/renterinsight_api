# API V1 Websites Controller
# Handles CRUD operations for websites

class Api::V1::WebsitesController < ApplicationController
  # Public preview endpoint - no auth required
  skip_before_action :authenticate, only: [:by_token, :by_slug_public]
  
  before_action :set_company_scope, except: [:by_token, :by_slug_public]
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
    
    website_json = @website.as_json(
      include: {
        website_pages: { only: [:id, :title, :slug, :is_visible, :page_order] },
        blog_posts: { only: [:id, :title, :slug, :status, :published_at] }
      }
    )

    # Include inventory embed config so website builder can auto-configure inventory blocks
    website_json['inventory_embed_config'] = {
      token: @company.public_inventory_token,
      company_id: @company.id,
      enabled: @company.public_inventory_enabled || false
    }

    # Include calculator settings from company loan_settings
    website_json['calculator_settings'] = build_calculator_settings(@company)

    render json: website_json
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
      # Create pages from template if template_data provided
      if params[:template_data].present?
        create_pages_from_template(@website, params[:template_data])
      else
        # Create default home page if no template
        @website.website_pages.create!(
          title: 'Home',
          path: '/',
          order: 0,
          is_visible: true,
          blocks: []
        )
      end
      
      render json: @website.as_json(
        include: {
          website_pages: { only: [:id, :title, :path, :is_visible, :order] }
        }
      ), status: :created
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
  #
  # Option C: "Smart Defaults + Optional Reset"
  #   - ALWAYS syncs: theme, brand, nav_config, header logo, footer logo/company name
  #   - OPTIONALLY (reset_block_colors=true): clears explicit color overrides from
  #     block content so they fall back to theme at render time. This is better than
  #     writing colors INTO blocks because future theme changes auto-cascade.
  #
  def sync_branding
    return unless authorize_action!('websites', 'update')
    
    source_type = params[:source_type] # 'company' or 'location'
    location_id = params[:location_id]
    reset_block_colors = ActiveModel::Type::Boolean.new.cast(params[:reset_block_colors])
    
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
    
    # --- ALWAYS: Sync theme, brand, nav_config ---
    @website.theme = (@website.theme || {}).merge(branding_data[:theme])
    @website.brand = (@website.brand || {}).merge(branding_data[:brand])
    @website.nav_config = (@website.nav_config || {}).merge(branding_data[:nav_config])

    logo_url = branding_data[:brand][:logo_url]
    company_name = branding_data[:brand][:company_name]

    primary_color = branding_data[:theme][:primary_color]
    secondary_color = branding_data[:theme][:secondary_color]

    # --- ALWAYS: Sync header logo + colors ---
    # Header is site chrome — should always match branding
    if @website.site_header.present? && @website.site_header['enabled']
      header = @website.site_header.dup
      header['logo'] = logo_url if logo_url.present?
      header['backgroundColor'] = '#ffffff'
      header['textColor'] = '#1f2937'
      @website.site_header = header
    end

    # --- ALWAYS: Sync footer logo, name + colors ---
    # Footer is site chrome — should always match branding
    if @website.site_footer.present? && @website.site_footer['enabled']
      footer = @website.site_footer.dup
      footer['logoUrl'] = logo_url if logo_url.present?
      footer['companyName'] = company_name if company_name.present?
      footer['backgroundColor'] = secondary_color || '#111827'
      footer['textColor'] = '#d1d5db'
      footer['headingColor'] = '#ffffff'
      @website.site_footer = footer
    end

    # --- OPTIONAL: Reset block color overrides ---
    # When enabled, REMOVES explicit color overrides from block content.
    # This makes blocks fall back to theme colors at render time,
    # so future theme changes auto-cascade without re-syncing.
    synced_blocks = 0
    if reset_block_colors
      # Map of block_type => array of content keys to clear
      # Removing these keys makes renderers fall back to theme colors
      color_overrides_to_clear = {
        'stats'           => %w[accentColor],
        'banner'          => %w[backgroundColor textColor],
        'inventorySearch'  => %w[searchButtonColor search_button_color],
        'hero'            => %w[ctaColor ctaTextColor],
        'cta'             => %w[buttonColor buttonTextColor backgroundColor textColor],
        'features'        => %w[accentColor],
        'pricing'         => %w[accentColor highlightColor],
        'comparison'      => %w[highlightColor],
      }

      @website.website_pages.each do |page|
        blocks = page.blocks
        next unless blocks.is_a?(Array)

        changed = false
        blocks.each do |block|
          keys_to_clear = color_overrides_to_clear[block['type']]
          next unless keys_to_clear
          content = block['content']
          next unless content.is_a?(Hash)

          keys_to_clear.each do |key|
            if content.key?(key)
              content.delete(key)
              changed = true
            end
          end
        end

        if changed
          page.update_column(:blocks, blocks)
          synced_blocks += 1
        end
      end

      Rails.logger.info "[Website Sync] Reset block color overrides on #{synced_blocks} page(s)"
    end
    
    synced_fields = branding_data.keys + ['site_header', 'site_footer']
    synced_fields << 'block_colors_reset' if reset_block_colors

    if @website.save
      render json: {
        website: @website,
        synced_from: source_type,
        synced_fields: synced_fields,
        synced_blocks: synced_blocks,
        block_colors_reset: reset_block_colors || false
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
  
  # PUBLIC ENDPOINT - No authentication required
  # GET /api/v1/websites/by_token/:token
  def by_token
    @website = Website.find_by!(preview_token: params[:token])
    
    website_json = @website.as_json(
      include: {
        website_pages: {
          only: [:id, :title, :slug, :path, :is_visible, :order, :blocks],
          methods: [:full_path]
        }
      },
      methods: [:full_theme]
    )
    
    # Include recent published blog posts for blogList blocks
    published_posts = @website.blog_posts
                              .where(is_deleted: [false, nil])
                              .where(status: :published)
                              .where('published_at <= ?', Time.current)
                              .order(published_at: :desc)
                              .limit(12)
    
    website_json['blog_posts'] = published_posts.as_json(
      only: [:id, :title, :slug, :excerpt, :featured_image_url, :featured_image_alt,
             :published_at, :view_count],
      include: {
        author: { only: [:id, :first_name, :last_name] },
        blog_categories: { only: [:id, :name, :slug] }
      },
      methods: [:reading_time]
    )
    
    # Include blog categories
    website_json['blog_categories'] = @website.blog_categories
                                              .where(is_deleted: [false, nil])
                                              .order(:order, :name)
                                              .as_json(only: [:id, :name, :slug], methods: [:posts_count])
    
    # Include calculator settings from company loan_settings
    website_json['calculator_settings'] = build_calculator_settings(@website.company)

    # Include inventory embed config for public preview
    website_json['inventory_embed_config'] = {
      token: @website.company.public_inventory_token,
      company_id: @website.company.id,
      enabled: @website.company.public_inventory_enabled || false
    }

    render json: website_json
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Preview not found' }, status: :not_found
  end

  # GET /api/v1/websites/by_slug_public/:slug
  # PUBLIC endpoint - no auth required. Used by /s/:slug preview in new tabs (Safari compatibility)
  def by_slug_public
    @website = Website.joins(:company)
                      .where(slug: params[:slug], is_deleted: [false, nil])
                      .first!

    website_json = @website.as_json(
      include: {
        website_pages: {
          only: [:id, :title, :slug, :path, :is_visible, :order, :blocks, :show_in_nav, :show_in_footer, :page_order],
          methods: [:full_path]
        }
      },
      methods: [:full_theme]
    )

    # Include recent published blog posts for blogList blocks
    published_posts = @website.blog_posts
                              .where(is_deleted: [false, nil])
                              .where(status: :published)
                              .where('published_at <= ?', Time.current)
                              .order(published_at: :desc)
                              .limit(12)

    website_json['blog_posts'] = published_posts.as_json(
      only: [:id, :title, :slug, :excerpt, :featured_image_url, :featured_image_alt,
             :published_at, :view_count],
      include: {
        author: { only: [:id, :first_name, :last_name] },
        blog_categories: { only: [:id, :name, :slug] }
      },
      methods: [:reading_time]
    )

    website_json['blog_categories'] = @website.blog_categories
                                              .where(is_deleted: [false, nil])
                                              .order(:order, :name)
                                              .as_json(only: [:id, :name, :slug], methods: [:posts_count])

    website_json['calculator_settings'] = build_calculator_settings(@website.company)

    website_json['inventory_embed_config'] = {
      token: @website.company.public_inventory_token,
      company_id: @website.company.id,
      enabled: @website.company.public_inventory_enabled || false
    }

    render json: website_json
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  # GET /api/v1/websites/by_slug/:slug
  # Authenticated preview - returns full website data for the site preview route
  def by_slug
    return unless authorize_action!('websites', 'read')

    @website = @company.websites.find_by!(slug: params[:slug])

    website_json = @website.as_json(
      include: {
        website_pages: {
          only: [:id, :title, :slug, :path, :is_visible, :order, :blocks, :show_in_nav, :show_in_footer, :page_order],
          methods: [:full_path]
        }
      },
      methods: [:full_theme]
    )

    # Include inventory embed config
    website_json['inventory_embed_config'] = {
      token: @company.public_inventory_token,
      company_id: @company.id,
      enabled: @company.public_inventory_enabled || false
    }

    # Include calculator settings from company loan_settings
    website_json['calculator_settings'] = build_calculator_settings(@company)

    # Include recent published blog posts for blogList blocks
    published_posts = @website.blog_posts
                              .where(is_deleted: [false, nil])
                              .where(status: :published)
                              .where('published_at <= ?', Time.current)
                              .order(published_at: :desc)
                              .limit(12)

    website_json['blog_posts'] = published_posts.as_json(
      only: [:id, :title, :slug, :excerpt, :featured_image_url, :featured_image_alt,
             :published_at, :view_count],
      include: {
        author: { only: [:id, :first_name, :last_name] },
        blog_categories: { only: [:id, :name, :slug] }
      },
      methods: [:reading_time]
    )

    # Include blog categories
    website_json['blog_categories'] = @website.blog_categories
                                              .where(is_deleted: [false, nil])
                                              .order(:order, :name)
                                              .as_json(only: [:id, :name, :slug], methods: [:posts_count])

    render json: website_json
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
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

  def set_company_scope
    company_id = request.headers['X-Company-ID'] || params[:company_id]
    
    if company_id.blank?
      render json: { error: 'Missing company context' }, status: :unauthorized
      return
    end
    
    @company = Company.find_by(id: company_id)
    
    unless @company
      render json: { error: 'Company not found' }, status: :not_found
      return
    end
  end

  # Build public-safe calculator settings from company loan_settings JSONB
  def build_calculator_settings(company)
    loan_settings = company.loan_settings || {}
    {
      enabled: loan_settings['calculator_enabled'] != false,
      defaultInterestRate: (loan_settings['default_interest_rate'] || 6.99).to_f,
      defaultLoanTermMonths: (loan_settings['max_loan_term'] || 240).to_i,
      minDownPaymentPercent: (loan_settings['min_down_payment_percent'] || 10).to_f,
      includeLotRent: loan_settings['calculator_include_lot_rent'] == true,
      defaultLotRentMonthly: (loan_settings['calculator_default_lot_rent'] || 0).to_f,
      includePropertyTax: loan_settings['calculator_include_property_tax'] == true,
      defaultPropertyTaxRate: (loan_settings['calculator_default_property_tax_rate'] || 1.0).to_f,
      includeInsurance: loan_settings['calculator_include_insurance'] == true,
      defaultInsuranceAnnual: (loan_settings['calculator_default_insurance_annual'] || 0).to_f,
      includeSetupFee: loan_settings['calculator_include_setup_fee'] == true,
      defaultSetupFee: (loan_settings['calculator_default_setup_fee'] || 0).to_f,
      loanTermOptions: (loan_settings['calculator_loan_term_options'] || [120, 180, 240, 300, 360]).map(&:to_i),
      disclaimerText: loan_settings['calculator_disclaimer_text'] || 'This calculator provides estimates only. Actual rates, terms, and payments may vary based on credit qualification and lender requirements. Contact us for personalized financing options.'
    }
  end

  def set_website
    # ALWAYS use scoped find - tenant isolation
    @website = @company.websites.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end
  
  # Helper to create pages from template data
  def create_pages_from_template(website, template_data)
    pages = template_data[:pages] || template_data['pages'] || []
    
    Rails.logger.info "[Website] Creating #{pages.length} pages from template for website #{website.id}"
    
    pages.each_with_index do |page_data, index|
      page_data = page_data.with_indifferent_access if page_data.is_a?(Hash)
      
      website.website_pages.create!(
        title: page_data[:title] || page_data[:name],
        path: page_data[:path] || "/#{(page_data[:title] || page_data[:name]).to_s.parameterize}",
        order: page_data[:order] || index,
        is_visible: page_data[:is_visible].nil? ? true : page_data[:is_visible],
        blocks: page_data[:blocks] || []
      )
    end
    
    Rails.logger.info "[Website] Successfully created #{pages.length} pages for website #{website.id}"
  rescue => e
    Rails.logger.error "[Website] Failed to create pages from template: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    # Don't fail the website creation, just log the error
  end
  
  # Helper to ensure color has # prefix
  def normalize_color(color)
    return nil if color.blank?
    color = color.to_s.strip
    color.start_with?('#') ? color : "##{color}"
  end
  
  # Extract branding from Location settings
  # FIXED: Uses company branding as proper fallback since LocationSettingsResolver cascade wasn't working
  def extract_location_branding(location)
    # First try location's own branding_settings (the raw column, not resolver)
    location_branding = location.branding_settings || {}
    Rails.logger.info "[Website Sync] Location own branding_settings: #{location_branding.inspect}"
    
    # Get company branding as base/fallback
    company_branding = Setting.get('Company', location.company.id, 'branding') || {}
    Rails.logger.info "[Website Sync] Company branding for fallback: #{company_branding.inspect}"
    
    # Location colors (check both camelCase and snake_case)
    loc_primary = location_branding['primaryColor'] || location_branding['primary_color']
    loc_secondary = location_branding['secondaryColor'] || location_branding['secondary_color']
    loc_font = location_branding['fontFamily'] || location_branding['font_family']
    loc_logo = location_branding['logo'] || location_branding['logo_url'] || location_branding['portalLogo']
    
    # Company colors (check both camelCase and snake_case)
    company_primary = company_branding['primaryColor'] || company_branding['primary_color']
    company_secondary = company_branding['secondaryColor'] || company_branding['secondary_color']
    company_font = company_branding['fontFamily'] || company_branding['font_family']
    company_logo = company_branding['logo'] || company_branding['logo_url'] || company_branding['portalLogo']
    
    # Use location values if present, otherwise fall back to company, then defaults
    primary_color = normalize_color(loc_primary.presence || company_primary) || '#3b82f6'
    secondary_color = normalize_color(loc_secondary.presence || company_secondary) || '#8b5cf6'
    font_family = loc_font.presence || company_font || 'Inter'
    logo = loc_logo.presence || company_logo
    
    Rails.logger.info "[Website Sync] Final location branding - primary: #{primary_color}, secondary: #{secondary_color}, font: #{font_family}"
    
    {
      theme: {
        primary_color: primary_color,
        secondary_color: secondary_color,
        font_family: font_family
      },
      brand: {
        company_name: location.company.name,
        logo_url: logo,
        phone: location.phone,
        email: location.email,
        address: location.address_line1,
        city: location.city,
        state: location.state,
        zip: location.zip_code,
        country: location.country || 'US'
      }.compact,
      nav_config: {
        logo_position: 'left',
        layout: 'horizontal',
        sticky: true
      }
    }
  end
  
  # Extract branding from Company settings
  def extract_company_branding(company)
    company_branding = Setting.get('Company', company.id, 'branding') || {}
    
    Rails.logger.info "[Website Sync] Company branding: #{company_branding.inspect}"
    
    # Handle both camelCase and snake_case keys
    primary_color = normalize_color(company_branding['primaryColor'] || company_branding['primary_color']) || '#3b82f6'
    secondary_color = normalize_color(company_branding['secondaryColor'] || company_branding['secondary_color']) || '#8b5cf6'
    font_family = company_branding['fontFamily'] || company_branding['font_family'] || 'Inter'
    logo = company_branding['logo'] || company_branding['logo_url'] || company_branding['portalLogo']
    
    Rails.logger.info "[Website Sync] Final company branding - primary: #{primary_color}, secondary: #{secondary_color}, font: #{font_family}"
    
    {
      theme: {
        primary_color: primary_color,
        secondary_color: secondary_color,
        font_family: font_family
      },
      brand: {
        company_name: company.name,
        logo_url: logo,
        phone: company_branding['phone'],
        email: company_branding['email']
      }.compact,
      nav_config: {
        logo_position: 'left',
        layout: 'horizontal',
        sticky: true
      }
    }
  end

  def website_params
    permitted = params.require(:website).permit(
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
        :font_size_base,
        :heading_font,
        :header_style,
        :footer_style,
        :custom_css
      ],
      nav_config: {},  # Allow any nested JSON structure for navigation config
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
        custom_scripts: [:head, :body]
      ]
    )
    # CRITICAL: NEVER permit company_id

    # FIX: site_header and site_footer are JSONB columns with deeply nested structures
    # (arrays of hashes like columns/socialLinks). Rails permit(key: {}) only passes
    # scalar values and silently STRIPS arrays, causing footer.enabled and columns
    # to be lost on create. Use permit! to preserve the full nested JSON structure.
    if params.dig(:website, :site_header).present?
      permitted[:site_header] = params[:website][:site_header].permit!.to_h
    end
    if params.dig(:website, :site_footer).present?
      permitted[:site_footer] = params[:website][:site_footer].permit!.to_h
    end

    permitted
  end
end
