class Template < ApplicationRecord
  # Associations
  belongs_to :company
  
  # String-backed enum on the `template_type` column
  enum :template_type, { email: 'email', sms: 'sms' }

  CATEGORIES = %w[
    general cold_outreach warm_followup nurture re_engagement
    appointment post_sale onboarding service referral_request
    announcement event_promo seasonal
  ].freeze

  SOURCES = %w[manual ai_generated].freeze

  # Attachments for email templates (PDFs, documents, images, etc.)
  has_many_attached :attachments

  validates :name, presence: true
  validates :template_type, presence: true
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true
  validates :source, inclusion: { in: SOURCES }, allow_nil: true

  scope :for_category, ->(cat) { where(category: cat) }
  scope :ai_generated, -> { where(source: 'ai_generated') }
  scope :manual, -> { where(source: 'manual') }
  
  # Validate attachment size and type
  validate :validate_attachments, if: -> { attachments.attached? }
  
  # Maximum size per attachment (10 MB)
  MAX_ATTACHMENT_SIZE = 10.megabytes
  
  # Allowed content types
  ALLOWED_ATTACHMENT_TYPES = %w[
    application/pdf
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    image/jpeg
    image/jpg
    image/png
    image/gif
    text/plain
    text/csv
  ].freeze
  
  private
  
  def validate_attachments
    return unless attachments.attached?
    
    attachments.each do |attachment|
      # Validate size
      if attachment.byte_size > MAX_ATTACHMENT_SIZE
        errors.add(:attachments, "#{attachment.filename} is too large (maximum is #{MAX_ATTACHMENT_SIZE / 1.megabyte}MB)")
      end
      
      # Validate content type
      unless ALLOWED_ATTACHMENT_TYPES.include?(attachment.content_type)
        errors.add(:attachments, "#{attachment.filename} has an invalid file type")
      end
    end
  end
end
