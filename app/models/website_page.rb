class WebsitePage < ApplicationRecord
  # Associations
  belongs_to :website
  belongs_to :parent_page, class_name: 'WebsitePage', optional: true
  has_many :child_pages, class_name: 'WebsitePage', foreign_key: :parent_page_id
  
  # Validations
  validates :title, presence: true
  validates :path, presence: true, uniqueness: { scope: :website_id }
  
  # Callbacks
  before_validation :generate_path, if: -> { path.blank? }
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :visible, -> { where(is_visible: true) }
  scope :visible_in_nav, -> { where(show_in_nav: true) }
  scope :visible_in_footer, -> { where(show_in_footer: true) }
  scope :top_level, -> { where(parent_page_id: nil) }
  
  # Visibility
  def show!
    update!(is_visible: true)
  end
  
  def hide!
    update!(is_visible: false)
  end
  
  private
  
  def generate_path
    return if title.blank?
    self.path = "/#{title.parameterize}"
  end
end
