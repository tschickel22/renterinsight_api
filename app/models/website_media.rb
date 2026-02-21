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
    # Return the permanent public S3 URL (not presigned)
    # The bucket policy makes objects publicly accessible,
    # so presigned URLs are unnecessary and cause expiration issues
    # when stored in header/footer configs.
    if url.present? && url.start_with?('http')
      url
    elsif s3_key.present?
      # Build permanent public URL from s3_key
      bucket = s3_bucket.presence || ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'
      region = ENV['AWS_REGION'] || 'us-west-2'
      "https://#{bucket}.s3.#{region}.amazonaws.com/#{s3_key}"
    elsif ENV['CDN_DOMAIN'].present?
      "https://#{ENV['CDN_DOMAIN']}/#{url}"
    else
      url
    end
  end

  # Generate a temporary presigned URL (use only when private access is needed)
  def presigned_url(expires_in: 3600)
    return nil unless s3_key.present?
    s3_service = S3UploadService.new
    s3_service.presigned_url(s3_key, expires_in: expires_in)
  end
end
