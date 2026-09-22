# frozen_string_literal: true

module Campaigns
  # Whether this campaign actually has someone to send as, answered per
  # recipient, before it runs.
  #
  # Owner mode resolves a different mailbox for every recipient, so a campaign
  # can start perfectly happily and then send nothing: reps who never connected
  # a mailbox, and reps on Gmail, which campaign mail may not use. Neither shows
  # up at start, because refusing to start would be wrong — one rep on Gmail
  # must not stop a campaign for the four who are not.
  #
  # The answer is to say so rather than to block. This is that number.
  class SenderCoverage
    Result = Struct.new(:total, :usable, :google, :missing, :owners, :fixed_sender, keyword_init: true) do
      def blocked = google + missing
      def all_covered? = blocked.zero?
    end

    def self.for_campaign(campaign)
      new(campaign).call
    end

    def initialize(campaign)
      @campaign = campaign
    end

    def call
      # A waterfall campaign always has a sender: the recipient's location
      # settings, then the company's, then the platform's. Nothing to warn about.
      return all_usable if @campaign.email_waterfall?
      return fixed_sender_result unless @campaign.owner_identity?

      recipients = audience_recipients
      return empty if recipients.empty?

      usable = 0
      google = 0
      missing = 0
      owners = Hash.new { |h, k| h[k] = { count: 0, reason: nil, name: nil } }

      # Owner mode resolves per recipient, but recipients share owners. Resolve
      # once per owner rather than once per recipient, or a 5,000 person
      # audience means 5,000 connection lookups to answer one question.
      recipients.group_by { |r| r.try(:owner_id) }.each do |owner_id, group|
        status, label = classify(group.first)
        case status
        when :usable  then usable  += group.size
        when :google  then google  += group.size
        else               missing += group.size
        end
        next if status == :usable

        owners[owner_id] = { count: group.size, reason: status.to_s, name: label }
      end

      Result.new(
        total: recipients.size, usable: usable, google: google, missing: missing,
        owners: owners.values, fixed_sender: false
      )
    end

    private

    def classify(recipient)
      mailbox = @campaign.resolve_mailbox_connection_for_step(recipient: recipient)
      resolved = @campaign.resolve_email_connection_for_step(recipient: recipient)
      label = owner_label(recipient, mailbox)

      return [:usable, label] if resolved
      return [:google, label] if @campaign.google_mailbox?(mailbox)

      [:missing, label]
    end

    def owner_label(recipient, mailbox)
      mailbox.try(:email_address).presence ||
        recipient.try(:owner)&.email.presence ||
        'Unassigned'
    rescue StandardError
      'Unassigned'
    end

    # One sender for everybody, so the answer is the same for every recipient.
    # can_start? already refuses these outright; this is here so the panel can
    # explain the refusal rather than leaving the button greyed with no reason.
    def fixed_sender_result
      mailbox = @campaign.resolve_mailbox_connection_for_step
      resolved = @campaign.resolve_email_connection_for_step
      total = audience_recipients.size

      return Result.new(total: total, usable: total, google: 0, missing: 0, owners: [], fixed_sender: true) if resolved

      reason = @campaign.google_mailbox?(mailbox) ? 'google' : 'missing'
      Result.new(
        total: total, usable: 0,
        google: reason == 'google' ? total : 0,
        missing: reason == 'missing' ? total : 0,
        owners: [{ count: total, reason: reason, name: mailbox.try(:email_address) || 'No mailbox connected' }],
        fixed_sender: true
      )
    end

    def all_usable
      total = audience_recipients.size
      Result.new(total: total, usable: total, google: 0, missing: 0, owners: [], fixed_sender: false)
    end

    def empty
      Result.new(total: 0, usable: 0, google: 0, missing: 0, owners: [], fixed_sender: false)
    end

    def audience_recipients
      @audience_recipients ||= Campaigns::ConsentCoverage.new(@campaign).send(:audience_recipients)
    end
  end
end
