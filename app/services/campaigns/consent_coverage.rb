# frozen_string_literal: true

module Campaigns
  # How much of a campaign's audience actually holds marketing consent, answered
  # before the campaign runs rather than discovered afterwards.
  #
  # CampaignSender skips a recipient with no consent record. On its own that is
  # silent: the campaign reports itself as running, the enrollment advances, and
  # a dealer who imported a book of contacts watches a send of 800 quietly
  # become a send of 40 with nothing anywhere saying why.
  #
  # This is the number that has to be on screen before they press start.
  class ConsentCoverage
    Result = Struct.new(:total, :consented, :missing, :opted_out, :gate_enabled, keyword_init: true) do
      def blocked = missing + opted_out
      def all_covered? = blocked.zero?
    end

    def self.for_campaign(campaign)
      new(campaign).call
    end

    def initialize(campaign)
      @campaign = campaign
      @company = campaign.company
    end

    def call
      channel = @campaign.sms_channel? ? 'sms' : 'email'
      recipients = audience_recipients

      consented = 0
      opted_out = 0
      recipients.each do |r|
        pref = CommunicationPreference.find_by(
          recipient: r, channel: channel, category: 'marketing'
        )
        if pref.nil?
          next
        elsif pref.opted_in?
          consented += 1
        else
          opted_out += 1
        end
      end

      Result.new(
        total: recipients.size,
        consented: consented,
        opted_out: opted_out,
        missing: recipients.size - consented - opted_out,
        gate_enabled: gate_enabled?
      )
    end

    # The recipients with no preference row at all. Deliberately NOT the opted
    # out ones: those people answered, and a bulk confirmation must never
    # overturn an answer somebody gave.
    def uncovered_recipients
      channel = @campaign.sms_channel? ? 'sms' : 'email'
      audience_recipients.reject do |r|
        CommunicationPreference.exists?(
          recipient: r, channel: channel, category: 'marketing'
        )
      end
    end

    private

    # A tenant that has opted out of the gate is not blocked by any of this, and
    # saying "40 recipients will be skipped" to them would be a lie. The counts
    # still come back, because knowing how much of your book has consent is
    # worth seeing either way.
    def gate_enabled?
      setting = Setting.get('Company', @company.id, 'require_marketing_consent')
      setting.nil? ? true : ActiveModel::Type::Boolean.new.cast(setting) != false
    end

    # Running campaigns have real enrollments; a draft has only the audience
    # definition, so it gets resolved the same way the enroller would.
    def audience_recipients
      if @campaign.campaign_enrollments.where(status: %w[pending active]).exists?
        @campaign.campaign_enrollments
                 .where(status: %w[pending active])
                 .filter_map { |e| e.recipient_type.safe_constantize&.find_by(id: e.recipient_id) }
      else
        enroller = AudienceEnroller.new(campaign: @campaign)
        enroller.send(:each_source_type).flat_map do |source_type|
          enroller.send(:audience_scope_for, source_type).to_a
        end
      end
    rescue StandardError => e
      Rails.logger.error("[ConsentCoverage] campaign #{@campaign.id}: #{e.class}: #{e.message}")
      []
    end
  end
end
