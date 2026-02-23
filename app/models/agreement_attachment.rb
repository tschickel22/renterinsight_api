class AgreementAttachment < ApplicationRecord
  belongs_to :agreement
  belongs_to :attachable, polymorphic: true
  belongs_to :attached_by, class_name: 'User', optional: true

  validates :attachable_type, presence: true
  validates :attachable_id, presence: true
  validates :attachable_type, uniqueness: {
    scope: [:agreement_id, :attachable_id],
    message: 'is already attached to this agreement'
  }

  # Supported attachable types
  ATTACHABLE_TYPES = %w[Contact Account Deal Quote Vehicle Property Supplier Lease ServiceTicket].freeze

  validates :attachable_type, inclusion: { in: ATTACHABLE_TYPES, message: '%{value} is not a valid attachment type' }
end
