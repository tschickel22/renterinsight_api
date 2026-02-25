class AgreementAttachment < ApplicationRecord
  belongs_to :agreement
  belongs_to :attachable, polymorphic: true, optional: true
  belongs_to :attached_by, class_name: 'User', optional: true

  # Validate either file or entity link is present
  validate :file_or_entity_present

  # Supported attachable types (for entity-linked attachments)
  ATTACHABLE_TYPES = %w[Contact Account Deal Quote Vehicle Property Supplier Lease ServiceTicket].freeze

  validates :attachable_type, inclusion: { in: ATTACHABLE_TYPES, message: '%{value} is not a valid attachment type' }, allow_nil: true

  private

  def file_or_entity_present
    if file_url.blank? && attachable_type.blank?
      errors.add(:base, 'Either a file or an entity link is required')
    end
  end
end
