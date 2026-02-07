class Website < ApplicationRecord
  # Multi-tenancy
  belongs_to :company
  belongs_to :location, optional: true
  
  # Associations - specify class_name for media to avoid pluralization issues
  has_many :website_pages, dependent: :destroy
  has_many :website_media, class_name: 'WebsiteMedia', dependent: :destroy
  has_many :blog_posts, dependent: :destroy
  has_many :website_versions, dependent: :destroy
  
  # Enums - Rails 8 syntax (only status for Phase 1, others can be added later with prefixes)
  enum :status, { draft: 0, published: 1, unpublished: 2 }, default: :draft
  
  # Validations
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :company_id }
  validates :domain, uniqueness: { scope: :company_id, allow_nil: true }
  validates :subdomain, uniqueness: { allow_nil: true }
  
  # Callbacks
  before_validation :generate_slug, if: -> { slug.blank? }
  before_validation :set_defaults, on: :create
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :for_current_location, -> { 
    Current.location_filtered? ? where(location_id: Current.location_id) : all 
  }
  
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
  end
end
