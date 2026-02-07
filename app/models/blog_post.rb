class BlogPost < ApplicationRecord
  belongs_to :website
  belongs_to :author, class_name: 'User'
  has_and_belongs_to_many :blog_categories, join_table: 'blog_posts_categories'
  
  # Enums - Rails 8 syntax
  enum :status, { draft: 0, published: 1, scheduled: 2 }, default: :draft
  
  # Validations
  validates :title, presence: true
  validates :slug, presence: true, uniqueness: { scope: :website_id }
  
  # Callbacks
  before_validation :generate_slug, if: -> { slug.blank? }
  before_save :extract_excerpt, if: -> { excerpt.blank? && content.present? }
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :published_posts, -> { where(status: :published).where('published_at <= ?', Time.current) }
  
  # Publishing workflow
  def publish!
    update!(status: :published, published_at: Time.current)
  end
  
  def unpublish!
    update!(status: :draft, published_at: nil)
  end
  
  def schedule!(publish_time)
    update!(status: :scheduled, scheduled_at: publish_time)
  end
  
  # Reading time calculation (assumes ~200 words per minute)
  def reading_time
    return 0 if content.blank?
    
    # Strip HTML tags and count words
    text = ActionView::Base.full_sanitizer.sanitize(content)
    word_count = text.split.size
    
    # Calculate minutes (minimum 1 minute)
    minutes = (word_count / 200.0).ceil
    [minutes, 1].max
  end
  
  # Extract plain text excerpt
  def excerpt_text
    return excerpt if excerpt.present?
    return '' if content.blank?
    
    # Strip HTML and truncate
    text = ActionView::Base.full_sanitizer.sanitize(content)
    text.truncate(200, separator: ' ')
  end
  
  # View tracking
  def increment_views!
    increment!(:view_count)
  end
  
  # URL generation
  def public_url(base_url)
    "#{base_url}/blog/#{slug}"
  end
  
  private
  
  def generate_slug
    return if title.blank?
    self.slug = title.parameterize
  end
  
  def extract_excerpt
    return if content.blank?
    
    # Extract first paragraph or first 200 characters
    text = ActionView::Base.full_sanitizer.sanitize(content)
    self.excerpt = text.truncate(200, separator: ' ')
  end
end
