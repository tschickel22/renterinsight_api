# frozen_string_literal: true

# A factory decor sheet a platform admin uploaded, and how reading it went.
class CatalogSwatchSheet < ApplicationRecord
  STATUSES = %w[queued reading done failed].freeze

  belongs_to :manufacturer
  belongs_to :factory, optional: true
  has_many :swatches, class_name: 'CatalogSwatch', dependent: :nullify

  validates :filename, :storage_ref, presence: true
  validates :status, inclusion: { in: STATUSES }
end
