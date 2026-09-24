# frozen_string_literal: true

# Records marketing consent that a member of staff is entering on a record,
# rather than consent a person gave us directly on a form.
#
# This exists because dealers arrive with contacts they already have consent
# for: an old CRM, a signed form in a filing cabinet, a conversation on the lot.
# Refusing to record that would not protect anybody. It would just mean the
# consent goes unrecorded while the dealer mails them anyway.
#
# But a consent a rep ticked is not the same kind of evidence as a consent a
# person gave, and the difference has to survive in the record. So a staff entry
# is stored with its own source, the user who entered it, and what they said
# their basis was. A reviewer can tell the two apart at a glance, which is the
# whole point: the alternative is a system where every consent looks
# form-captured and none of them can be trusted.
class MarketingConsentRecorder
  SOURCE = 'staff_entry'
  CATEGORY = 'marketing'
  CHANNELS = %w[email sms].freeze

  Result = Struct.new(:ok, :error, keyword_init: true) do
    def ok? = ok
  end

  def self.call(recipient:, opted_in:, user:, basis: nil)
    new(recipient: recipient, opted_in: opted_in, user: user, basis: basis).call
  end

  def initialize(recipient:, opted_in:, user:, basis: nil)
    @recipient = recipient
    @opted_in = ActiveModel::Type::Boolean.new.cast(opted_in)
    @user = user
    @basis = basis.to_s.strip.presence
  end

  def call
    return Result.new(ok: false, error: 'No record to record consent against') if @recipient.nil?

    # Recording a consent is an assertion about somebody else, so it carries a
    # reason. Recording a refusal does not: "they asked me to stop" needs no
    # justification and demanding one would discourage honouring it.
    if @opted_in && @basis.blank?
      return Result.new(ok: false, error: 'Say where this consent came from before recording it')
    end

    ActiveRecord::Base.transaction do
      CHANNELS.each { |channel| write(channel) }
    end

    Result.new(ok: true)
  rescue StandardError => e
    Rails.logger.error("[MarketingConsentRecorder] #{@recipient.class}##{@recipient&.id}: #{e.class}: #{e.message}")
    Result.new(ok: false, error: e.message)
  end

  private

  def write(channel)
    pref = CommunicationPreference.find_or_create_for(
      recipient: @recipient, channel: channel, category: CATEGORY
    )

    if @opted_in
      pref.opt_in!
    else
      pref.opt_out!('Recorded by staff')
    end

    pref.update!(
      compliance_metadata: (pref.compliance_metadata || {}).merge(
        'source' => SOURCE,
        'recorded_by_user_id' => @user&.id,
        'recorded_by_name' => @user.try(:name).presence || [@user.try(:first_name), @user.try(:last_name)].compact.join(' ').presence,
        'recorded_at' => Time.current.iso8601,
        'basis' => @basis,
        # A staff entry never carries the consent text a form would: nobody was
        # shown anything. Clearing it stops an earlier form capture's wording
        # being read as evidence for a later staff entry.
        'consent_text' => nil,
        'consent_version' => nil
      ).compact
    )
  end
end
