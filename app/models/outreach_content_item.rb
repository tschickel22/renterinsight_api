# frozen_string_literal: true

# A video or link Proactive Outreach may send (backlog E105). Only approved
# items are ever offered to a lead.
class OutreachContentItem < ApplicationRecord
  STATUSES = %w[pending approved archived].freeze
  SOURCE_KINDS = %w[manual campaign training_video].freeze

  belongs_to :company
  belongs_to :approved_by_user, class_name: 'User', optional: true

  before_validation :clean_text

  validates :title, :url, presence: true
  validates :url, format: { with: %r{\Ahttps?://[^\s]+\z}i, message: 'must be a full web address' }
  validates :url, uniqueness: { scope: :company_id, message: 'is already in your content' }
  validates :status, inclusion: { in: STATUSES }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }

  scope :approved, -> { where(status: 'approved') }

  def approve!(user)
    update!(status: 'approved', approved_by_user_id: user&.id, approved_at: Time.current)
  end

  private

  # Nothing a customer reads carries an em or en dash.
  def clean_text
    self.url = url.to_s.strip
    %i[title topic use_when description].each do |field|
      value = self[field]
      self[field] = Assistant::Rules.tidy(value) unless value.nil?
    end
  end
end
