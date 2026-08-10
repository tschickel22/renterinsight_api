class Website < ApplicationRecord
  # Multi-tenancy
  belongs_to :company
  belongs_to :location, optional: true
  
  # Associations - specify class_name for media to avoid pluralization issues
  has_many :website_pages, dependent: :destroy
  has_many :website_media, class_name: 'WebsiteMedia', dependent: :destroy
  has_many :blog_posts, dependent: :destroy
  has_many :blog_categories, dependent: :destroy
  has_many :website_versions, dependent: :destroy

  # The address visitors type to reach this site. Assigned on the domain screen, where the
  # DNS records and verification state live, and surfaced here so someone who has just
  # finished building a site can tell whether anyone can actually reach it.
  #
  # nullify rather than destroy: deleting a site must not silently take a verified domain
  # with it, along with its certificate and the DNS the dealer published by hand.
  has_many :company_domains, dependent: :nullify

  # What to tell the builder about reachability. Serving requires the domain to be wired up
  # AND the site to be published, and either one missing produces an address that resolves
  # to nothing, so both are reported rather than a single boolean.
  def domain_status
    domain = company_domains.detect(&:web_enabled?)
    return { state: 'none' } if domain.nil?

    {
      state: domain.ready_for_use? ? (published? ? 'live' : 'awaiting_publish') : 'awaiting_dns',
      hostname: domain.hostname,
      url: "https://#{domain.hostname}"
    }
  end


  # Where a visitor can actually reach this site right now, or nil when nobody can.
  #
  # The builder used to send every Preview click to the in-app /s/:slug route, which is
  # correct for a draft and misleading for a live site: it shows the CRM's hostname to
  # someone who just published to their own. Callers fall back to /s/:slug when this is
  # nil, so a draft still previews.
  #
  # Computed here rather than assembled in the client because the hostname depends on
  # PLATFORM_SITE_LABEL_SUFFIX, which is a server-side environment concern the browser
  # has no way to know. See Websites::SiteAddress.
  #
  # Matches what HostResolver actually serves: a custom domain when it is wired up and
  # the site is published, otherwise the platform subdomain, and the status column
  # rather than published? so this cannot claim an address the resolver would refuse.
  def public_url
    live = domain_status
    return live[:url] if live[:state] == 'live'
    return nil unless status == 'published'

    host = Websites::SiteAddress.host_for(self)
    host.presence && "https://#{host}"
  end

  # The address this site takes on our platform, published or not.
  #
  # public_url deliberately answers nil for a draft, because it states where a
  # site IS reachable. The builder needs the other question: where it WILL be.
  # Without that the form printed the host root from a constant in the browser
  # and was simply wrong on staging, where every host carries a label suffix, so
  # a dealer was shown an address that answers 403.
  def platform_host
    Websites::SiteAddress.host_for(self)
  rescue StandardError
    nil
  end

  # Enums - Rails 8 syntax (only status for Phase 1, others can be added later with prefixes)
  enum :status, { draft: 0, published: 1, unpublished: 2 }, default: :draft

  # What this Website is for.
  #
  # 'site'      — a dealer's real website, built and managed in the site editor.
  # 'marketing' — the system-owned container that holds landing pages. Created
  #               automatically, never listed, never editable as a site. It
  #               exists because a landing page is a WebsitePage and a
  #               WebsitePage needs a Website — including for a dealer who bought
  #               only the landing page module and has no site with us at all.
  KINDS = %w[site marketing].freeze

  # Every user-facing website read should go through .sites. A marketing
  # container in the websites list invites a dealer to edit or delete the thing
  # their landing pages are served from.
  scope :sites, -> { where(kind: 'site') }
  scope :marketing_containers, -> { where(kind: 'marketing') }

  def marketing_container?
    kind == 'marketing'
  end

  # Validations
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :slug, presence: true, uniqueness: { scope: :company_id }
  validates :domain, uniqueness: { scope: :company_id, allow_blank: true }
  validates :subdomain, uniqueness: { allow_blank: true }
  # Format and reserved names were never checked, so a site could take "www" or
  # "origin" — the latter being the Cloudflare for SaaS fallback origin every
  # dealer custom domain resolves through — or an address with characters no
  # hostname may contain.
  validate :subdomain_is_usable
  validates :location_id, presence: { message: 'must be selected' }
  
  # Callbacks
  before_validation :nullify_blank_domain_fields
  before_validation :generate_slug, if: -> { slug.blank? }
  before_validation :set_defaults, on: :create
  before_create :generate_preview_token

  # A platform subdomain resolves through the wildcard record, but Render
  # rejects any Host it does not recognise, so the site is only reachable once
  # the host-rewriting Worker is bound to that exact hostname. Keeping the
  # route in step with the column is the difference between a subdomain that
  # serves and one that answers 403.
  #
  # after_commit, not after_save: enqueueing inside the transaction races the
  # worker, which can read the row before the commit lands.
  after_commit :sync_subdomain_worker_route, on: %i[create update]
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :for_current_location, -> { 
    Current.location_filtered? ? where(location_id: Current.location_id) : all 
  }
  
  # Returns theme with defaults merged in
  def full_theme
    defaults = {
      'primary_color' => '#3b82f6',
      'secondary_color' => '#8b5cf6',
      'accent_color' => '#f59e0b',
      'font_family' => 'Inter'
    }
    defaults.merge(theme || {})
  end

  # Publishing workflow
  def publish!
    update!(status: :published, published_at: Time.current)
  end
  
  def unpublish!
    update!(status: :unpublished)
  end
  
  def published?
    status == 'published' && published_at.present?
  end
  
  # Versioning
  def create_version!(created_by_id:)
    website_versions.create!(
      snapshot_data: as_snapshot,
      created_by_id: created_by_id,
      is_current: false
    )
  end
  
  def as_snapshot
    {
      name: name,
      slug: slug,
      domain: domain,
      subdomain: subdomain,
      theme: theme,
      nav_config: nav_config,
      brand: brand,
      seo_config: seo_config,
      tracking_config: tracking_config,
      site_header: site_header,
      site_footer: site_footer,
      favicon_url: favicon_url,
      pages: website_pages.active.map do |page|
        {
          title: page.title,
          path: page.path,
          order: page.order,
          is_visible: page.is_visible,
          blocks: page.blocks,
          seo_title: page.seo_title,
          seo_description: page.seo_description
        }
      end
    }
  end
  
  private

  # Enqueues only when something that changes the answer actually changed.
  # Every other save on a website — a theme tweak, a nav edit — must not spend
  # a Cloudflare call.
  #
  # A soft delete is a subdomain that should stop answering, so it enqueues too
  # and the job unbinds rather than rebinds.
  def sync_subdomain_worker_route
    return unless saved_change_to_subdomain? || saved_change_to_is_deleted?

    previous_host = previous_subdomain_host
    return if previous_host.blank? && subdomain.blank?

    WebsiteSubdomainRouteJob.perform_later(id, previous_host)
  rescue StandardError => e
    # Never let route bookkeeping fail a save the user asked for.
    Rails.logger.warn("[Website] could not enqueue subdomain route sync for #{id}: #{e.message}")
  end

  # The host the PREVIOUS subdomain served on, so a rename unbinds the old one.
  # Nil when the subdomain did not change, since there is nothing to clean up.
  def previous_subdomain_host
    return nil unless saved_change_to_subdomain?

    old = saved_change_to_subdomain.first.presence
    return nil if old.blank?

    Websites::SiteAddress.host_for_subdomain(old)
  end

  def subdomain_is_usable
    return if subdomain.blank?

    return if Websites::SubdomainSuggester.valid?(subdomain)

    errors.add(:subdomain, if Websites::SubdomainSuggester.reserved?(subdomain)
                             'is reserved. Please choose another.'
                           else
                             'may use only lowercase letters, numbers and hyphens, ' \
                             "and must be #{Websites::SubdomainSuggester::MIN_LENGTH}" \
                             "-#{Websites::SubdomainSuggester::MAX_LENGTH} characters."
                           end)
  end

  def nullify_blank_domain_fields
    self.domain = nil if domain.blank?
    self.subdomain = nil if subdomain.blank?
  end

  def generate_slug
    return if name.blank?
    self.slug = name.parameterize
  end
  
  def set_defaults
    self.status ||= :draft
    self.theme ||= {}
    self.nav_config ||= {}
    self.brand ||= {}
    self.seo_config ||= {}
    self.tracking_config ||= {}
    self.site_header ||= {}
    self.site_footer ||= {}
  end
  
  def generate_preview_token
    # Generate a unique 10-character alphanumeric token
    loop do
      self.preview_token = SecureRandom.alphanumeric(10)
      break unless Website.exists?(preview_token: preview_token)
    end
  end
end
