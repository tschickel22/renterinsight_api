class WebsiteMedia < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :website
  
  # Enums - Rails 8 syntax
  enum :file_type, { image: 0, video: 1, document: 2, other: 3 }, default: :other
  
  # Validations
  validates :name, presence: true
  validates :url, presence: true
  validates :file_size, presence: true, numericality: { greater_than: 0 }
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :images, -> { where(file_type: :image) }
  scope :videos, -> { where(file_type: :video) }
  scope :documents, -> { where(file_type: :document) }
  
  # URL helpers
  def full_url
    # If S3 key exists, generate presigned URL for temporary access
    if s3_key.present?
      s3_service = S3UploadService.new
      s3_service.presigned_url(s3_key, expires_in: 3600) || url
    else
      # Fallback to stored URL
      return url if url.start_with?('http')
      "https://#{ENV['CDN_DOMAIN']}/#{url}"
    end
  end
end
