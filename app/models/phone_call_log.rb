# frozen_string_literal: true

# One call reported by a dealer's phone system. See PhoneCalls::Recorder.
class PhoneCallLog < ApplicationRecord
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :loggable, polymorphic: true, optional: true

  before_save { self.payload = (payload || {}).deep_stringify_keys }

  scope :recent, -> { order(created_at: :desc) }
  scope :matched, -> { where.not(loggable_id: nil) }
  scope :unmatched, -> { where(loggable_id: nil) }

  def matched?
    loggable_id.present?
  end
end
