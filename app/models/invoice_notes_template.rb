class InvoiceNotesTemplate < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :notes, presence: true

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :default_template, -> { where(is_default: true) }
end
