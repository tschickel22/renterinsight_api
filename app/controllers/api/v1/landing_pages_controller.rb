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
  include ModuleAccessRequired

  before_action :set_company_scope

  # Paid add-on. Campaign Desk grants it implicitly
  # (PlatformModule::IMPLIED_MODULES), so a Desk tenant passes this without a
  # second entitlement; everyone else needs it added to their subscription.
  require_module! 'marketing.landing_pages'

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

    # A landing page with no form silently drops every lead, so one is built
    # unless the caller deliberately bound an existing form.
    if page.intake_form_id.blank?
      page.intake_form = build_intake_form(page.title)
      bind_form_to_contact_blocks(page)
    end

    if page.save
      render json: detail(page), status: :created
    else
      render json: { error: page.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue Marketing::MarketingSiteProvisioner::ProvisioningError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/landing_pages/ai_generate
  #
  # Returns a PLAN, not a page: profile sections, a form field list and a
  # layout hint. Projection into blocks happens on the frontend, where the
  # layouts live — same split the site profile importer already uses, and the
  # reason previewing every layout costs nothing.
  def ai_generate
    return unless authorize_action!('websites', 'create')

    brief = Marketing::Brief.new(
      company: @company,
      user: current_user,
      location: target_location,
      prompt: params[:prompt].to_s,
      site_content_profile: resolve_profile,
      offer: params[:offer].presence,
      audience: params[:audience].presence,
      tone: params[:tone].presence,
      call_to_action: params[:call_to_action].presence
    )

    if brief.prompt.blank? && brief.site_content_profile.nil?
      return render json: { error: 'Describe the page, or pick a scanned document to build it from.' },
                    status: :unprocessable_entity
    end

    result = LandingPages::AiBuilder.new(company: @company, user: current_user).generate(brief: brief)
    render json: result.except(:usage)
  rescue LandingPages::AiBuilder::CreditLimitError => e
    render json: { error: e.message }, status: :payment_required
  rescue LandingPages::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST /api/v1/landing_pages/import_html
  #
  # A page designed elsewhere, kept as itself. The block importer reproduces
  # content in our design system, which is the right trade for a page a dealer
  # will maintain and the wrong one for a page whose design is the pitch. This
  # rehosts the assets, drops anything executable, and stores the result as a
  # single customHtml block.
  def import_html
    return unless authorize_action!('websites', 'create')

    site = Marketing::MarketingSiteProvisioner.call(company: @company, location: target_location)
    result = LandingPages::HtmlImporter.new(company: @company, website: site).call(params[:file])

    page = site.website_pages.new(
      title: params[:title].presence || File.basename(params[:file].original_filename.to_s, '.*'),
      page_kind: 'landing',
      blocks: [{ 'id' => "block_#{SecureRandom.hex(6)}", 'type' => 'customHtml', 'order' => 0,
                 'content' => { 'html' => result.html,
                                # Every video in the design, as an empty slot the
                                # editor can point at an MP4 in the media library.
                                'videoSlots' => result.video_slots,
                                'videos' => {} } }]
    )

    # Same reason as create: a landing page with no form silently drops every
    # lead. The design's own form markup is inert once scripts are gone, so a
    # real one is appended rather than left to look like it works.
    page.intake_form = build_intake_form(page.title)

    # Only when the design has no form of its own. It usually does, and the
    # importer has just wired it, so appending ours as well would put two forms
    # on one page asking for the same three things.
    if page.intake_form.present? && result.forms_wired.zero?
      page.blocks += [{
        'id' => "block_#{SecureRandom.hex(6)}", 'type' => 'contact', 'order' => 1,
        'content' => { 'title' => 'Request details', 'displayMode' => 'inline' }
      }]
    end

    if page.save
      bind_form_to_contact_blocks(page)
      # The design's own forms were wired at import; they address the public
      # intake endpoint by public id, which only exists once the form is saved.
      if result.forms_wired.positive? && page.intake_form.present?
        page.blocks = Array(page.blocks).map do |block|
          next block unless block['type'].to_s == 'customHtml'

          content = block['content'].is_a?(Hash) ? block['content'] : {}
          block.merge('content' => content.merge(
            'intakeFormPublicId' => page.intake_form.public_id
          ))
        end
      end
      page.save
      render json: detail(page).merge(
        import: { imported: result.imported, skipped: result.skipped,
                  warnings: result.warnings, video_slots: result.video_slots,
                  forms_wired: result.forms_wired }
      ), status: :created
    else
      render json: { error: page.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue LandingPages::HtmlImporter::ImportError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Marketing::MarketingSiteProvisioner::ProvisioningError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    return unless authorize_action!('websites', 'update')

    previous_form_id = @page.intake_form_id
    @page.assign_attributes(page_params)

    # SiteRenderer reads the form off the contact block before it falls back to
    # the page. Left alone, changing the editor's form picker moved the page's
    # own intake_form_id and left every contact block still naming the previous
    # form, so the picker looked like it had worked while the leads kept going
    # to the form the author had just switched away from.
    # Unconditionally, not only when the picker moved.
    #
    # Gating on a change meant a page bound before this rebinding existed could
    # never heal: its form does not change on a later save, so the rebind never
    # ran and the design kept posting to whichever form the importer stamped.
    # Page 29 in production sat that way — page-level form set to Facebook
    # Contact, design still posting to its auto-generated one with no source, so
    # every lead recorded as "Web Form".
    #
    # Safe for contact blocks, which keep their own rule: with the form
    # unchanged, one following the page is rewritten to the value it already
    # holds, and one deliberately bound elsewhere is still left alone.
    rebind_form_blocks(@page, previous_form_id)

    if @page.save
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

  # GET /api/v1/landing_pages/comparison
  #
  # The question the per-page report cannot answer: which of these is doing
  # better. Answering it meant opening each page in turn and holding the numbers
  # in your head.
  def comparison
    return unless authorize_action!('websites', 'read')

    render json: Marketing::LandingPageComparison.new(
      company_landing_pages.order(:title),
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

  def resolve_profile
    return nil if params[:site_content_profile_id].blank?

    SiteContentProfile.find_by(id: params[:site_content_profile_id], company_id: @company.id)
  end

  def build_intake_form(title)
    Marketing::LandingPageFormBuilder.new(
      company: @company,
      title: title.presence || 'Landing Page',
      fields: params[:form_fields],
      location: target_location,
      notified_user: current_user
    ).call
  rescue StandardError => e
    # A page without a form is recoverable — the editor can bind one. A failed
    # create is not.
    Rails.logger.warn("[LandingPages] form build failed: #{e.message}")
    nil
  end

  # SiteRenderer reads the form id off the contact block, so the column and the
  # block have to agree or the page renders "Contact form not available".
  def bind_form_to_contact_blocks(page)
    return if page.intake_form_id.blank?

    page.blocks = Array(page.blocks).map do |block|
      next block unless block['type'].to_s == 'contact'

      content = block['content'].is_a?(Hash) ? block['content'] : {}
      block.merge('content' => content.merge('intakeFormId' => page.intake_form_id))
    end
  end

  # The colours a landing page should actually render in.
  #
  # MarketingSiteProvisioner creates the container with an empty theme, and
  # nothing has ever filled it in, so every landing page fell through to
  # SiteRenderer's hardcoded #3b82f6 and came out the same default blue no
  # matter whose dealership it belonged to. The company's own branding is
  # already resolved for embedded inventory; the same answer is the right one
  # here.
  #
  # Resolved at read time rather than written at provision time so containers
  # that already exist are corrected too, and so a dealer who later changes
  # their brand colour does not have to rebuild their landing pages.
  def preview_theme(page)
    theme = (page.website&.theme || {}).dup
    return theme if theme['primary_color'].present?

    branding = @company.resolve_branding_for_inventory(
      website: page.website,
      location: page.website&.location
    )
    primary = branding[:primary_color] || branding['primary_color']
    secondary = branding[:secondary_color] || branding['secondary_color']

    theme['primary_color'] = primary if primary.present?
    theme['secondary_color'] = secondary if secondary.present?
    theme
  rescue StandardError => e
    # A colour is not worth failing a page load over.
    Rails.logger.warn("[LandingPages] theme resolve failed: #{e.message}")
    page.website&.theme || {}
  end

  # Point contact blocks at the page's current form.
  #
  # Only blocks that were following the page are moved: one deliberately bound
  # to some other form is somebody's decision, and changing the page-level
  # default must not overrule it.
  def rebind_form_blocks(page, previous_form_id)
    public_id = page.intake_form_id.present? ? public_form_id_for(page.intake_form_id) : nil

    page.blocks = Array(page.blocks).map do |block|
      content = block['content'].is_a?(Hash) ? block['content'] : {}

      # An imported design is a single customHtml block that names its form by
      # PUBLIC id, because the design's own markup is posted straight to the
      # public endpoint. Only 'contact' was rebound, so on the one kind of page
      # where this picker is the sole way to choose a form, choosing did
      # nothing: the page's intake_form_id moved and the design kept posting to
      # whichever form the importer stamped at import time. Leads from a paid ad
      # landed under an auto-generated form with no source, and were attributed
      # to "Web Form" rather than to the campaign that paid for them.
      #
      # Rebound unconditionally, unlike a contact block: there is no per-block
      # form picker on an imported design, so a value that differs from the page
      # is stale rather than deliberate.
      if block['type'].to_s == 'customHtml'
        next block if public_id.nil?
        # Corrected whenever it disagrees, not only when the picker moved.
        # There is no per-block form picker on an imported design, so a value
        # that differs from the page is stale rather than deliberate.
        next block if content['intakeFormPublicId'].to_s == public_id.to_s

        next block.merge('content' => content.merge('intakeFormPublicId' => public_id))
      end

      next block unless block['type'].to_s == 'contact'

      bound = content['intakeFormId']
      following = bound.blank? || bound.to_s == previous_form_id.to_s
      next block unless following

      block.merge('content' => content.merge('intakeFormId' => page.intake_form_id))
    end
  end

  # Scoped to the company, so a form id that somehow reached here can never
  # bind a page to another tenant's form.
  def public_form_id_for(form_id)
    @company.intake_forms.where(id: form_id).pick(:public_id)
  end

  def page_params
    params.permit(
      :title, :path, :is_visible, :seo_title, :seo_description, :og_image_url,
      :robots, :canonical_path, :intake_form_id, :layout_id,
      style: {},
      # Named rather than a bare hash: the custom head/body fields are injected
      # into the document as written, so what may be set here is worth being
      # explicit about.
      tracking_config: [
        :google_analytics_id, :google_tag_manager_id, :facebook_pixel_id, :hotjar_id,
        { custom_scripts: %i[head body] }
      ],
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
      canonical_path: page.canonical_path,
      tracking_config: page.tracking_config,
      # What the page inherits from its container, so the editor can say which
      # tags already fire here rather than inviting a duplicate pixel.
      inherited_tracking_config: page.website&.tracking_config || {},
      # What the editor and the detail preview need to render the page the way
      # a visitor sees it. Without the embed config SiteRenderer has no token to
      # give the intake form, so every contact block in the builder said
      # "Contact form not available" no matter which form was bound; without the
      # theme the preview drew in default blue while the published page used the
      # site's colours, which is the one thing a preview must not do.
      theme: preview_theme(page),
      # The container's header/footer switches, which for a landing page are
      # deliberately off. Sent because SiteRenderer treats a missing site_header
      # as "never configured" and falls back to a generated nav bar carrying the
      # site name, so a preview that was not given them grew a header the
      # published page does not have, captioned with the page's internal title.
      site_header: page.website&.site_header,
      site_footer: page.website&.site_footer,
      inventory_embed_config: {
        token: @company.public_inventory_token,
        company_id: @company.id,
        enabled: @company.public_inventory_enabled || false
      }
    )
  end

  # Built from the same resolution order Websites::HostResolver uses, so what
  # the builder shows is what a visitor would actually type.
  def public_url_for(page)
    site = page.website
    return nil if site.nil?

    host = site.company_domains.detect(&:web_enabled?)&.hostname
    host ||= site.domain.presence
    # site_host_root, not subdomain_root: the platform domain has no wildcard
    # record, so a URL built on it named a host that does not resolve and the
    # View button opened a browser error page.
    host ||= Websites::SiteAddress.host_for(site) if site.subdomain.present?
    return nil if host.blank?

    "https://#{host}#{page.path}"
  end
end
