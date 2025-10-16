# frozen_string_literal: true

class PortalDocument < ApplicationRecord
  # Active Storage attachment
  has_one_attached :file
  
  # Polymorphic associations
  belongs_to :owner, polymorphic: true
  belongs_to :related_to, polymorphic: true, optional: true
  
  # Validations
  validates :owner_type, presence: true, inclusion: { in: %w[Lead Account BuyerPortalAccess] }
  validates :owner_id, presence: true
  validates :category, inclusion: { 
    in: %w[insurance registration invoice receipt other contract warranty manual photo], 
    allow_nil: true 
  }
  # Note: File presence is validated in acceptable_file callback
  
  # Custom validation for file
  validate :acceptable_file, on: :create
  
  # Scopes
  scope :by_owner, ->(owner) { where(owner: owner) }
  scope :by_category, ->(category) { where(category: category) }
  scope :recent, -> { order(uploaded_at: :desc) }
  
  # Callbacks
  before_create :set_uploaded_at
  
  # File type validation
  ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    image/png
    image/jpeg
    image/jpg
    image/gif
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  ].freeze
  
  MAX_FILE_SIZE = 10.megabytes
  
  # Instance methods
  def filename
    file.attached? ? file.filename.to_s : ''
  end
  
  def content_type
    file.content_type if file.attached?
  end
  
  def size
    file.byte_size if file.attached?
  end
  
  def download_url
    "/api/portal/documents/#{id}/download"
  end
  
  private
  
  def acceptable_file
    unless file.attached?
      errors.add(:file, "can't be blank")
      return
    end
    
    unless file.byte_size <= MAX_FILE_SIZE
      errors.add(:file, "is too large (max #{MAX_FILE_SIZE / 1.megabyte}MB)")
    end
    
    unless ALLOWED_CONTENT_TYPES.include?(file.content_type)
      errors.add(:file, "type not allowed (#{file.content_type})")
    end
  end
  
  def set_uploaded_at
    self.uploaded_at ||= Time.current
  end
end
