# frozen_string_literal: true

# Scan a client's existing site into a reusable Content Profile.
#
# Scanning must live here (CORS, the Anthropic key, a minutes-long crawl), but
# PROJECTION DOES NOT. The nine templates are TypeScript data in the frontend,
# so the frontend projects the profile into them — that avoids duplicating the
# templates across two repos and makes switching designs instant instead of a
# round trip per template. This controller serves profiles; the client renders.
#
# Platform admin only, EXCEPT #by_token — the whole point of the shared preview
# is that a salesperson can send it to someone with no account.
class Api::V1::SiteContentProfilesController < ApplicationController
  # Generous, because a print-resolution dealer brochure is legitimately large.
  # Only the first pages are ever rendered or read, so this bounds the upload
  # and the S3 object, not the scan.
  MAX_DOCUMENT_BYTES = 40.megabytes

  # What SiteProfiles::DocumentIngestor can actually read. Checked here so the
  # admin is told immediately, rather than by a job that fails a minute later.
  SUPPORTED_DOCUMENT_TYPES = (
    SiteProfiles::DocumentIngestor::PDF_TYPES +
    SiteProfiles::DocumentIngestor::IMAGE_TYPES +
    SiteProfiles::DocumentIngestor::TEXT_TYPES
  ).freeze

  skip_before_action :authenticate, only: [:by_token]

  before_action :require_platform_admin!, except: [:by_token]
  before_action :set_company_scope, except: [:by_token]
  before_action :set_profile, only: %i[show destroy rotate_preview_token update engagement]

  def index
    profiles = SiteContentProfile.where(company_id: @company.id).order(created_at: :desc).limit(100)
    render json: { items: profiles.map { |p| summary(p) } }
  end

  def show
    render json: detail(@profile)
  end

  # POST /api/v1/site_content_profiles
  #   { source_url: }    -> scan an existing site (async)
  #   { manual: {...} }  -> build from a short form, ready immediately
  #   { document: file } -> scan an uploaded product sheet or brochure (async)
  def create
    return create_manual if params[:manual].present?
    return create_from_document if params[:document].present?

    url = params[:source_url].to_s.strip

    # Fail fast on an unsafe URL so the admin sees a real error now, rather than
    # a job that dies quietly three minutes later.
    begin
      SiteProfiles::UrlGuard.validate!(url)
    rescue SiteProfiles::UrlGuard::BlockedUrlError => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    profile = SiteContentProfile.create!(
      company_id: @company.id,
      location_id: params[:location_id].presence,
      created_by: current_user,
      source_url: url,
      display_name: params[:display_name].presence,
      preview_template_ids: Array(params[:preview_template_ids]).map(&:to_s),
      inventory_company_id: params[:inventory_company_id].presence,
      status: 'pending'
    )

    SiteProfileScanJob.perform_later(profile.id)
    render json: detail(profile), status: :created
  end

  # No crawl and no AI call — the content came straight from the admin, so the
  # profile is shareable the moment it is saved.
  def create_manual
    attrs = params.require(:manual).permit(
      :business_name, :tagline, :logo_url, :primary_color, :font,
      :phone, :email, :address, :headline, :subhead, :about_heading, :about
    )

    built = SiteProfiles::ProfileSchema.from_manual(attrs)

    profile = SiteContentProfile.create!(
      company_id: @company.id,
      location_id: params[:location_id].presence,
      created_by: current_user,
      source_url: nil,
      display_name: params[:display_name].presence || attrs[:business_name].presence,
      preview_template_ids: Array(params[:preview_template_ids]).map(&:to_s),
      inventory_company_id: params[:inventory_company_id].presence,
      profile: built,
      schema_version: SiteProfiles::ProfileSchema::VERSION,
      status: 'ready'
    )

    render json: detail(profile), status: :created
  end

  # Scan an uploaded document — a product sheet, brochure or spec packet.
  #
  # The file goes to S3 rather than travelling with the job: extraction takes
  # minutes and runs on a background worker, so the bytes have to outlive the
  # request. Keeping the object also means a profile can be re-extracted later
  # against a better prompt without asking for the file again.
  def create_from_document
    upload = params[:document]
    unless upload.respond_to?(:read)
      return render json: { error: 'No document was uploaded.' }, status: :unprocessable_entity
    end

    if upload.size.to_i > MAX_DOCUMENT_BYTES
      return render json: {
        error: "That document is #{(upload.size / 1.megabyte.to_f).round(1)}MB. " \
               "The limit is #{MAX_DOCUMENT_BYTES / 1.megabyte}MB."
      }, status: :unprocessable_entity
    end

    content_type = upload.content_type.to_s.downcase.presence

    # application/octet-stream means the browser did not recognise the file,
    # not that the file is unreadable. Chrome sends it for .md and, depending on
    # the OS, for perfectly ordinary PDFs — so rejecting it here refused files
    # DocumentIngestor#sniff_content_type would have identified from their
    # magic bytes a moment later. Let the sniffer decide those.
    unknown_type = content_type.nil? || content_type == 'application/octet-stream'
    unless SUPPORTED_DOCUMENT_TYPES.include?(content_type) || unknown_type
      return render json: {
        error: "#{content_type} is not supported. Upload a PDF, an image, or a text file."
      }, status: :unprocessable_entity
    end

    # Stored as nil rather than octet-stream so the ingestor sniffs instead of
    # trusting a value we already know is a guess.
    content_type = nil if unknown_type

    uploaded = S3UploadService.new.upload(upload, folder: "site-profiles/uploads/#{@company.id}")
    if uploaded.blank? || uploaded[:key].blank?
      return render json: { error: 'The document could not be stored. Try again.' },
                    status: :service_unavailable
    end

    profile = SiteContentProfile.create!(
      company_id: @company.id,
      location_id: params[:location_id].presence,
      created_by: current_user,
      source_kind: 'document',
      source_url: nil,
      document_filename: upload.original_filename,
      document_s3_key: uploaded[:key],
      document_content_type: content_type,
      document_byte_size: upload.size,
      display_name: params[:display_name].presence || File.basename(upload.original_filename.to_s, '.*'),
      preview_template_ids: Array(params[:preview_template_ids]).map(&:to_s),
      inventory_company_id: params[:inventory_company_id].presence,
      status: 'pending'
    )

    SiteProfileScanJob.perform_later(profile.id)
    render json: detail(profile), status: :created
  end

  # Curate which designs a customer sees, or set an expiry, without reissuing
  # the link.
  def update
    @profile.update!(
      display_name: params.fetch(:display_name, @profile.display_name),
      preview_template_ids: params.key?(:preview_template_ids) ? Array(params[:preview_template_ids]).map(&:to_s) : @profile.preview_template_ids,
      preview_expires_at: params.fetch(:preview_expires_at, @profile.preview_expires_at),
      inventory_company_id: params.key?(:inventory_company_id) ? params[:inventory_company_id].presence : @profile.inventory_company_id,
      suggested_subdomain: params.key?(:suggested_subdomain) ? normalized_subdomain(params[:suggested_subdomain]) : @profile.suggested_subdomain,
      # Governs the CLIENT's view only. The audit still ran and the admin can
      # still read it; see summary.
      show_seo_report: params.key?(:show_seo_report) ? ActiveModel::Type::Boolean.new.cast(params[:show_seo_report]) : @profile.show_seo_report
    )
    render json: detail(@profile)
  end

  # GET /api/v1/site_content_profiles/:id/engagement
  #
  # Whether the prospect we sent this to has opened it, and what held their
  # attention.
  def engagement
    render json: SiteProfiles::DemoEngagement.new(@profile).call
  end

  def rotate_preview_token
    @profile.rotate_preview_token!
    render json: { preview_token: @profile.preview_token }
  end

  def destroy
    @profile.destroy!
    head :no_content
  end

  # GET /api/v1/site_content_profiles/inventory_lots
  #
  # Which lots a demo can be pointed at, so the choice is made BEFORE the scan.
  # It has to be before: the manufacturer logos are derived from the lot's own
  # stock, so picking the lot afterwards means the demo advertises the wrong
  # brands until someone notices.
  #
  # Only lots that would actually render something — public inventory on, a
  # token issued, and stock to show. An enabled-but-empty lot produces an empty
  # grid, which is worse than not offering it.
  def inventory_lots
    lots = Company
           .where("companies.public_inventory_settings ->> 'public_inventory_enabled' IN (?)",
                  SiteProfiles::DemoInventoryResolver::ENABLED_VALUES)
           .where.not(public_inventory_token: [nil, ''])
           .joins(:vehicles)
           .where(vehicles: { status: SiteProfiles::DemoInventoryResolver::SELLABLE_STATUSES,
                              is_deleted: [false, nil] })
           .group('companies.id')
           .order(Arel.sql('COUNT(vehicles.id) DESC'))
           .limit(100)
           .pluck('companies.id', 'companies.name', Arel.sql('COUNT(vehicles.id)'))

    render json: {
      items: lots.map { |id, name, count| { id: id, name: name, home_count: count, is_current: id == @company.id } }
    }
  end

  # GET /api/v1/site_content_profiles/by_token/:token
  #
  # PUBLIC. Deliberately narrow: returns the content needed to render a preview
  # and nothing else — not the source URL, not the company, not who scanned it.
  def by_token
    profile = SiteContentProfile.find_by(preview_token: params[:token])
    return render json: { error: 'Preview not found' }, status: :not_found if profile.nil? || !profile.shareable?

    render json: {
      display_name: profile.display_name,
      profile: public_profile(profile),
      template_ids: profile.visible_template_ids,
      inventory_embed_config: inventory_config_for(profile),
      # Settings belong to whichever lot is being shown, not to the profile's
      # tenant: the calculator has to quote against the homes on screen. Absent
      # a lot there is nothing to finance, so the block stays hidden.
      calculator_settings: calculator_settings_for(profile),
      # Same lot again, and not by preference: the public intake endpoint
      # authenticates with the inventory token and scopes the form to that
      # company, so a form from anywhere else would 404.
      lead_form_id: lead_form_id_for(profile),
      # So the logo strip shows the brands this lot actually carries rather
      # than every mark we happen to host.
      manufacturers: manufacturers_for(profile),
      # The findings themselves only travel when the admin allowed it.
      seo_report: profile.show_seo_report ? profile.seo_report : nil,
      # The teaser travels either way, and carries no findings: enough to start
      # a conversation, not enough to act on without us. Nil when the audit
      # found nothing wrong, since there is nothing to tease.
      seo_teaser: seo_teaser_for(profile),
      # A demo is the first thing a prospect sees of us, so it carries the same
      # credit a built site does. From the kernel, so it moves with the brand.
      platform_brand: platform_brand
    }
  end

  private

  def set_profile
    @profile = SiteContentProfile.find_by(id: params[:id], company_id: @company.id)
    render json: { error: 'Not found' }, status: :not_found if @profile.nil?
  end

  # Everything the client needs to project, minus the provenance.
  def public_profile(profile)
    profile.profile.slice('schema_version', 'brand', 'contact', 'copy', 'media', 'links', 'integrations', 'seo')
  end

  # Memoised per request: #index renders many rows and the resolver would
  # otherwise run its lookup for each one.
  def inventory_config_for(profile)
    @inventory_configs ||= {}
    key = profile.inventory_company_id || :default
    return @inventory_configs[key] if @inventory_configs.key?(key)

    @inventory_configs[key] = SiteProfiles::DemoInventoryResolver.config_for_profile(profile)
  end

  # Follows the lot, not the tenant. A demo showing the nominated sample lot
  # quotes that lot's financing terms, which is what the homes on screen are
  # actually priced against.
  # Falls back to the profile's own tenant when no lot resolves.
  #
  # This used to return nil without a lot, which hid the calculator entirely —
  # so a demo for a prospect with no inventory to show also lost the one block
  # that works without any. "What would my payment be" is a fair question
  # before browsing, and it is often the first one a manufactured-housing buyer
  # asks. The block runs on its own default price when there is nothing to
  # pick from.
  def calculator_settings_for(profile)
    company = lot_company_for(profile) || profile.company
    return nil if company.nil?

    Websites::CalculatorSettings.for(company)
  end

  # A real, working contact form makes the difference between a demo a prospect
  # can picture themselves using and one with "Contact form not available"
  # where the form should be.
  def lead_form_id_for(profile)
    company = lot_company_for(profile)
    return nil if company.nil?

    Websites::DefaultLeadForm.for(company)&.id
  end

  # Sanitised the same way a generated one is, so what an admin types and what
  # the scan produces obey identical rules and neither can create an address a
  # Website would then refuse to save.
  # What a prospect sees when the full report is withheld.
  #
  # Deliberately only a count and the domain. Naming the gaps here would be the
  # report by another name, and the point of hiding it is that the findings are
  # the reason to call us.
  def platform_brand
    brand = Brand.current
    { name: brand.name, url: brand.website_url }
  rescue StandardError
    {}
  end

  def seo_teaser_for(profile)
    report = profile.seo_report
    return nil if report.blank?

    gaps = report['gap_count'].to_i
    return nil if gaps.zero?
    return nil if profile.show_seo_report

    {
      gap_count: gaps,
      domain: report['domain'],
      score: report['score']
    }
  end

  def normalized_subdomain(value)
    return nil if value.blank?

    Websites::SubdomainSuggester.normalize(value)
  end

  def manufacturers_for(profile)
    Websites::LotManufacturers.for(lot_company_for(profile))
  end

  # The company whose lot backs this demo. Memoised because three callers need
  # it and it is the same lookup each time.
  def lot_company_for(profile)
    config = inventory_config_for(profile)
    return nil if config.blank?

    @lot_companies ||= {}
    id = config['company_id']
    @lot_companies.fetch(id) { @lot_companies[id] = Company.find_by(id: id) }
  end

  def summary(profile)
    {
      id: profile.id,
      source_url: profile.source_url,
      display_name: profile.display_name,
      status: profile.status,
      preview_token: profile.preview_token,
      preview_expires_at: profile.preview_expires_at,
      preview_template_ids: profile.preview_template_ids,
      created_at: profile.created_at,
      page_count: profile.report['page_count'],
      source_kind: profile.source_kind,
      document_filename: profile.document_filename,
      # Zero means the document was read as text only — worth surfacing, since
      # it is the difference between a profile that matched the source's design
      # and one that inferred it from mangled extracted text.
      rasterized_page_count: profile.rasterized_page_count,
      inventory_company_id: profile.inventory_company_id,
      # The address this demo would take if committed. Editable while it is
      # still a demo; after that it belongs to the dealer.
      suggested_subdomain: profile.suggested_subdomain,
      inventory_is_sample: inventory_config_for(profile)&.dig('is_sample') || false,
      # Always present for an admin regardless of show_seo_report: the toggle
      # decides what the prospect sees, not what we can see.
      seo_report: profile.seo_report,
      show_seo_report: profile.show_seo_report
    }
  end

  def detail(profile)
    summary(profile).merge(
      profile: profile.profile,
      report: profile.report,
      schema_version: profile.schema_version,
      robots_allowed: profile.robots_allowed,
      error_message: profile.error_message,
      inventory_embed_config: inventory_config_for(profile)
    )
  end
end
