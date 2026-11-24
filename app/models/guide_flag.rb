# frozen_string_literal: true

# A question the help assistant handed to support instead of answering it
# (E118). The person was told someone will follow up, so looks_wrong and
# request rows email support as they are made; feature requests are read in
# bulk (Knowledge admin) and grouped by question.
#
#   looks_wrong      what they describe does not match the help, the product
#                    or their own setup: maybe a bug, maybe stale help
#   feature_request  something DealerTide does not do
#   request          they want something changed that the assistant cannot do
#   not_expressible  Report AI could not express the question as a report
class GuideFlag < ApplicationRecord
  KINDS = %w[looks_wrong feature_request request not_expressible].freeze
  STATUSES = %w[new triaged fixed not_a_bug built wont_do done].freeze
  SOURCES = %w[help sparkle report_ai].freeze
  TRACE_CHARS = 20_000

  belongs_to :company, optional: true
  belongs_to :user, optional: true
  belongs_to :guide_conversation, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :question, presence: true

  before_validation :trim

  scope :open_items, -> { where(status: %w[new triaged]) }

  # Support hears about these the moment they are made.
  def urgent?
    %w[looks_wrong request].include?(kind)
  end

  private

  def trim
    self.question = question.to_s.first(2_000)
    self.page = page.to_s.first(250).presence
    self.assistant_reason = assistant_reason.to_s.first(1_000).presence
    trace = Array(tool_trace)
    trace.pop while trace.size > 1 && trace.to_json.length > TRACE_CHARS
    self.tool_trace = trace
  end
end
