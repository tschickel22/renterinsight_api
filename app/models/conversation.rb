# frozen_string_literal: true

# An ongoing conversation with a buyer (backlog E96). The Lead Assistant answers
# while it is `active`; a person has it once `handed_off`; `closed` is done.
# Messages live in `communications` (conversation_id); this row holds who it is
# with, which number it runs on, who is handling it, and what the assistant has
# learned so far (`qualification`, string keys).
class Conversation < ApplicationRecord
  include LocationAware

  STATUSES = %w[active handed_off closed].freeze
  OPEN_STATUSES = %w[active handed_off].freeze
  CHANNELS = %w[sms email].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :conversable, polymorphic: true, optional: true
  belongs_to :assigned_user, class_name: 'User', optional: true
  belongs_to :handed_off_to_user, class_name: 'User', optional: true
  has_many :communications, dependent: :nullify
  has_many :conversation_reads, dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }
  validates :channel, inclusion: { in: CHANNELS }

  before_validation :normalize_numbers
  before_save { self.qualification = (qualification || {}).deep_stringify_keys }

  scope :open_now, -> { where(status: OPEN_STATUSES) }

  def self.normalize_phone(raw)
    digits = raw.to_s.gsub(/\D/, '')
    return nil if digits.blank?

    digits = "1#{digits}" if digits.length == 10
    "+#{digits}"
  end

  # The open conversation on this number with this buyer, if any. A pool number
  # names no dealer, so this pair is the only way to know whose reply it is.
  def self.open_for_numbers(sender_number:, buyer_phone:)
    open_now.find_by(sender_number: normalize_phone(sender_number), buyer_phone: normalize_phone(buyer_phone))
  end

  def assistant_answering?
    status == 'active' && assistant_enabled?
  end

  def handed_off?
    status == 'handed_off'
  end

  def merge_qualification!(fields)
    clean = fields.to_h.deep_stringify_keys.reject { |_, v| v.blank? }
    return if clean.empty?

    update!(qualification: (qualification || {}).merge(clean))
  end

  def note_message!(communication)
    attrs = {
      last_message_at: communication.created_at || Time.current,
      last_message_preview: communication.body.to_s.squish.truncate(140)
    }
    if communication.direction == 'inbound'
      attrs[:last_inbound_at] = attrs[:last_message_at]
      attrs[:unanswered_count] = 0
    else
      attrs[:last_outbound_at] = attrs[:last_message_at]
    end
    update_columns(attrs.merge(updated_at: Time.current))
  end

  private

  def normalize_numbers
    self.sender_number = self.class.normalize_phone(sender_number) if sender_number.present?
    self.buyer_phone = self.class.normalize_phone(buyer_phone) if buyer_phone.present?
  end
end
