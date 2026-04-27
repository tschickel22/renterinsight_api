class CampaignStep < ApplicationRecord
  belongs_to :campaign

  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :wait_days, numericality: { greater_than_or_equal_to: 0 }
  validates :wait_hours, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 23 }

  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(:position) }

  before_save :ensure_footer_unsubscribe

  private

  def ensure_footer_unsubscribe
    return if body_blocks.blank?
    return unless body_blocks.is_a?(Array)
    has_footer = body_blocks.any? { |b| b.is_a?(Hash) && (b['type'] == 'footer_unsubscribe' || b[:type] == 'footer_unsubscribe') }
    self.body_blocks = body_blocks + [{ 'type' => 'footer_unsubscribe' }] unless has_footer
  end
end
