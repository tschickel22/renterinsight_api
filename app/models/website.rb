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
  
  # Enums - Rails 8 syntax (only status for Phase 1, others can be added later with prefixes)
  enum :status, { draft: 0, published: 1, unpublished: 2 }, default: :draft
  
  # Validations
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :company_id }
  validates :domain, uniqueness: { scope: :company_id, allow_blank: true }
  validates :subdomain, uniqueness: { allow_blank: true }
  validates :location_id, presence: { message: 'must be selected' }
  
  # Callbacks
  before_validation :nullify_blank_domain_fields
  before_validation :generate_slug, if: -> { slug.blank? }
  before_validation :set_defaults, on: :create
  before_create :generate_preview_token
  
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
