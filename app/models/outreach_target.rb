# frozen_string_literal: true

# One lead in a wave (backlog E105). The held-back group gets no outreach; it is
# what the contacted group is measured against.
class OutreachTarget < ApplicationRecord
  GROUPS = %w[contact holdout].freeze
  STATUSES = %w[selected drafted approved skipped sending sent replied booked held stopped finished].freeze
  # Still being worked: follow-ups may go out.
  WORKING = %w[sent replied].freeze
  CHANNELS = %w[text email].freeze

  belongs_to :company
  belongs_to :outreach_wave
  belongs_to :lead
  belongs_to :conversation, optional: true
  has_many :outreach_events, dependent: :destroy

  validates :test_group, inclusion: { in: GROUPS }
  validates :status, inclusion: { in: STATUSES }
  validates :channel, inclusion: { in: CHANNELS }, allow_nil: true

  scope :contact_group, -> { where(test_group: 'contact') }

  def record!(event_type, channel: nil, communication_id: nil, at: Time.current, metadata: {})
    OutreachEvent.create!(company_id: company_id, outreach_wave_id: outreach_wave_id, outreach_target_id: id,
                          event_type: event_type, channel: channel, communication_id: communication_id,
                          occurred_at: at, metadata: metadata.deep_stringify_keys)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def recorded?(event_type)
    outreach_events.where(event_type: event_type).exists?
  end

  def stop!(reason)
    return if %w[stopped finished].include?(status)

    update!(status: 'stopped', stop_reason: reason, next_touch_at: nil)
  end
end
