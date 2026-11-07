# frozen_string_literal: true

# A question a buyer asked Quinn AI (E96). The unanswered ones are the
# dealer's list of answers to add (they become FAQs Quinn uses); all of them,
# across dealers, are what DealerTide learns from.
class AssistantQuestion < ApplicationRecord
  STATUSES = %w[answered unanswered handed_off dismissed].freeze
  TOPICS = %w[homes pricing financing land delivery location hours appointment process trade_in warranty other].freeze

  belongs_to :company
  belongs_to :conversation, optional: true
  belongs_to :communication, optional: true
  belongs_to :answered_by_user, class_name: 'User', optional: true

  validates :question, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :needing_answer, -> { where(status: %w[unanswered handed_off], dealer_answer: nil) }
end
