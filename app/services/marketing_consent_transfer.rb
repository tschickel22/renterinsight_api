# frozen_string_literal: true

# Carries a marketing consent forward when a lead becomes a contact and an account.
#
# CommunicationPreference is polymorphic on the recipient, so a consent captured
# on a lead form belongs to the Lead row and nothing else. Converting the lead
# produced a Contact and an Account that held no consent at all, and
# Campaigns::CampaignSender gates on exactly that record: the moment a dealer
# converted a consenting lead, the person became unmailable. Worse, it looked
# like the consent had been withdrawn rather than mislaid.
#
# Consent belongs to the PERSON, not to the row that happened to hold them, so
# it follows them forward.
class MarketingConsentTransfer
  CATEGORY = 'marketing'
  CHANNELS = %w[email sms].freeze

  def self.call(from:, to:)
    new(from: from, to: to).call
  end

  def initialize(from:, to:)
    @from = from
    @to = to
  end

  # Returns the number of preferences carried over.
  def call
    return 0 if @from.nil? || @to.nil?

    CHANNELS.count { |channel| copy(channel) }
  rescue StandardError => e
    # Never fail a conversion over this. A conversion that half-happened is far
    # worse than a consent row that has to be copied by hand, and the log line
    # names both records so it can be.
    Rails.logger.error(
      "[MarketingConsentTransfer] #{@from.class}##{@from&.id} -> #{@to.class}##{@to&.id}: #{e.class}: #{e.message}"
    )
    0
  end

  private

  def copy(channel)
    source = CommunicationPreference.find_by(
      recipient: @from, channel: channel, category: CATEGORY
    )
    return false if source.nil?

    target = CommunicationPreference.find_or_initialize_by(
      recipient: @to, channel: channel, category: CATEGORY
    )

    # An existing record on the target wins. The person may have unsubscribed as
    # a contact since, and a conversion must never resurrect a consent they
    # already withdrew.
    return false if target.persisted?

    target.assign_attributes(
      opted_in:    source.opted_in,
      opted_in_at: source.opted_in_at,
      opted_out_at: source.opted_out_at,
      opted_out_reason: source.opted_out_reason,
      ip_address:  source.ip_address,
      user_agent:  source.user_agent,
      # Provenance travels with it, so the record still proves what the person
      # was shown and when, rather than looking like it appeared at conversion.
      compliance_metadata: (source.compliance_metadata || {}).merge(
        'carried_from' => "#{@from.class.name}##{@from.id}",
        'carried_at' => Time.current.iso8601
      )
    )
    target.save!
    true
  end
end
