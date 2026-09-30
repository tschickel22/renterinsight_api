# frozen_string_literal: true

# A home a buyer designed and saved. See CreateTruebuildDesigns.
class TruebuildDesign < ApplicationRecord
  STATUSES = %w[saved quote_requested].freeze

  belongs_to :company
  belongs_to :variant, class_name: 'CatalogPlanVariant', foreign_key: :catalog_plan_variant_id
  belongs_to :vehicle, optional: true
  belongs_to :lead, optional: true
  belongs_to :intake_submission, optional: true
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :public_token, presence: true, uniqueness: true

  before_validation { self.public_token ||= SecureRandom.urlsafe_base64(12) }
  before_save { self.option_ids = Array(option_ids).map(&:to_i).uniq }

  def record_view!
    self.class.where(id: id).update_all(['view_count = view_count + 1, last_viewed_at = ?', Time.current])
  end
end
