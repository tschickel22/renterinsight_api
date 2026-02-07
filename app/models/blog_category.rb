class BlogCategory < ApplicationRecord
  belongs_to :website
  has_and_belongs_to_many :blog_posts, join_table: 'blog_posts_categories'
  
  # Validations
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :website_id }
  
  # Callbacks
  before_validation :generate_slug, if: -> { slug.blank? }
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  
  # Post counting
  def posts_count
    blog_posts.where(is_deleted: [false, nil]).count
  end
  
  private
  
  def generate_slug
    return if name.blank?
    self.slug = name.parameterize
  end
end
