class WebsiteMedia < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :website
  
  # Enums - Rails 8 syntax
  enum :file_type, { image: 0, video: 1, document: 2, other: 3 }, default: :other
  
  # Validations
  validates :file_name, presence: true
  validates :file_url, presence: true
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :images, -> { where(file_type: :image) }
  scope :videos, -> { where(file_type: :video) }
  scope :documents, -> { where(file_type: :document) }
  
  # URL helpers
  def full_url
    return file_url if file_url.start_with?('http')
    "https://#{ENV['CDN_DOMAIN']}/#{file_url}"
  end
end
