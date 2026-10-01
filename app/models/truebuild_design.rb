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
  belongs_to :contact, optional: true
  belongs_to :account, optional: true
  belongs_to :deal, optional: true
  belongs_to :quote, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :public_token, presence: true, uniqueness: true

  before_validation { self.public_token ||= SecureRandom.urlsafe_base64(12) }
  before_save { self.option_ids = Array(option_ids).map(&:to_i).uniq }

  # What happens to a saved design after it leaves the buyer's hands, for
  # follow up: each is counted on the design and raised as a workflow event
  # on the buyer (design_saved, design_viewed, design_shared, design_copied),
  # on the contact once the lead is converted, else on the lead.
  EVENTS = %w[saved viewed shared copied].freeze

  def record_view!
    self.class.where(id: id).update_all(['view_count = view_count + 1, last_viewed_at = ?', Time.current])
    # A link reopened ten times in an evening is one reason to call.
    track!('viewed') if Rails.cache.write("truebuild:design:viewed:#{id}", true, expires_in: 1.hour, unless_exist: true)
  end

  def track!(event, extra = {})
    return unless EVENTS.include?(event)

    if event == 'shared'
      self.class.where(id: id).update_all('share_count = share_count + 1')
    elsif event == 'copied'
      self.class.where(id: id).update_all(["metadata = jsonb_set(metadata, '{copies}', to_jsonb(COALESCE((metadata->>'copies')::int, 0) + 1))"])
    end
    buyer = contact || lead
    return unless buyer

    WorkflowEngine.emit("#{buyer.class.name.underscore}.design_#{event}", buyer,
                        { design_id: id, design_name: name, design_token: public_token, total: price_snapshot['total'] }.merge(extra))
  end
end
