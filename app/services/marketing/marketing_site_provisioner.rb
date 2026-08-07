# frozen_string_literal: true

module Marketing
  # Finds or creates the system-owned Website that a company's landing pages live on.
  #
  # A landing page is a WebsitePage, and a WebsitePage needs a Website. Dealers who
  # bought only the landing page module have no site with us, so one is provisioned
  # for them. It is a container, not a product surface: hidden from the websites
  # list, never opened in the site editor, and created at most once per company.
  #
  # Idempotent. Callers can invoke this on every landing page create without
  # checking first.
  class MarketingSiteProvisioner
    class ProvisioningError < StandardError; end

    SUBDOMAIN_SUFFIX = 'pages'

    def self.call(company:, location: nil)
      new(company: company, location: location).call
    end

    def initialize(company:, location: nil)
      @company = company
      @location = location
    end

    def call
      raise ProvisioningError, 'company is required' if @company.nil?

      existing = Website.active.marketing_containers.find_by(company_id: @company.id)
      return existing if existing

      create_container
    end

    private

    def create_container
      location_id = resolve_location_id
      if location_id.nil?
        raise ProvisioningError,
              "Company #{@company.id} has no active location; a website requires one"
      end

      Website.create!(
        company_id: @company.id,
        location_id: location_id,
        kind: 'marketing',
        name: "#{@company.name} Landing Pages",
        slug: unique_slug,
        subdomain: unique_subdomain,
        # Published on creation, deliberately.
        #
        # Websites::HostResolver only resolves sites with status 'published', and
        # this container is invisible — nobody will ever think to go publish it.
        # Leaving it draft would make every landing page unreachable with no
        # visible cause. Page-level published_at is what actually gates a landing
        # page, so a published container exposes nothing on its own.
        status: :published,
        published_at: Time.current,
        theme: {},
        nav_config: {},
        brand: {},
        seo_config: {},
        tracking_config: {},
        # No nav or footer chrome. Landing pages are single-purpose and render
        # their own header/footer treatment.
        site_header: { 'enabled' => false },
        site_footer: { 'enabled' => false }
      )
    rescue ActiveRecord::RecordInvalid => e
      raise ProvisioningError, "Could not provision marketing site: #{e.record.errors.full_messages.to_sentence}"
    end

    # Website validates location_id presence. Mirrors the corporate-first waterfall
    # IntakeSubmission uses so a landing page lands where an intake lead would.
    def resolve_location_id
      return @location.id if @location

      corporate = @company.locations.corporate.active.order(:id).first
      return corporate.id if corporate

      @company.locations.active.order(:id).first&.id
    end

    # Unique per company (Website validates slug uniqueness scoped to company).
    def unique_slug
      base = 'landing-pages'
      candidate = base
      suffix = 2
      while Website.where(company_id: @company.id, slug: candidate).exists?
        candidate = "#{base}-#{suffix}"
        suffix += 1
      end
      candidate
    end

    # Unique GLOBALLY — Website validates subdomain uniqueness with no company
    # scope, because a subdomain resolves to exactly one site across all tenants
    # (Websites::HostResolver#from_subdomain).
    def unique_subdomain
      base = "#{company_label}-#{SUBDOMAIN_SUFFIX}"
      candidate = base
      suffix = 2
      while Website.where(subdomain: candidate).exists?
        candidate = "#{base}-#{suffix}"
        suffix += 1
      end
      candidate
    end

    def company_label
      label = @company.subdomain.presence || @company.name.to_s.parameterize.presence
      label = "company-#{@company.id}" if label.blank?
      label.to_s.parameterize
    end
  end
end
