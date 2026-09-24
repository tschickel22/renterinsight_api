# frozen_string_literal: true

module Campaigns
  # A dealer confirming, in one action, that the people in this audience opted
  # in with them somewhere we did not record.
  #
  # This is the step that turns the consent gate from a wall into a question.
  # Without it, a dealer who imported a book of contacts has no route forward
  # except ticking several hundred leads by hand, which nobody will do: they
  # will turn the gate off instead, and then it protects no one.
  #
  # Three rules keep it from becoming a "make everything mailable" button:
  #
  #   It only ever touches recipients with NO record. Somebody who opted out
  #   answered the question, and no bulk action may overturn an answer.
  #
  #   It demands a stated basis, and stores it against the user who confirmed.
  #   A dealer asserting consent for 800 people should have to say where those
  #   800 came from, and be named in the record when they do.
  #
  #   Every row it writes is a staff entry. None of them pretend to be a form
  #   capture, so the consents people actually gave us stay distinguishable.
  class BulkConsentConfirmation
    # Large enough for a real migrated book, small enough that a runaway filter
    # cannot silently assert consent for an entire database.
    MAX_RECIPIENTS = 5_000

    Result = Struct.new(:ok, :confirmed, :error, keyword_init: true) do
      def ok? = ok
    end

    def self.call(campaign:, user:, basis:)
      new(campaign: campaign, user: user, basis: basis).call
    end

    def initialize(campaign:, user:, basis:)
      @campaign = campaign
      @user = user
      @basis = basis.to_s.strip
    end

    def call
      return Result.new(ok: false, confirmed: 0, error: 'Say where this consent came from') if @basis.blank?

      recipients = Campaigns::ConsentCoverage.new(@campaign).uncovered_recipients
      return Result.new(ok: true, confirmed: 0) if recipients.empty?

      if recipients.size > MAX_RECIPIENTS
        return Result.new(
          ok: false, confirmed: 0,
          error: "This audience has #{recipients.size} recipients without consent, more than the " \
                 "#{MAX_RECIPIENTS} that can be confirmed at once. Narrow the audience and try again."
        )
      end

      confirmed = 0
      recipients.each do |recipient|
        result = MarketingConsentRecorder.call(
          recipient: recipient, opted_in: true, user: @user, basis: @basis
        )
        confirmed += 1 if result.ok?
      end

      Rails.logger.info(
        "[BulkConsentConfirmation] campaign #{@campaign.id}: #{confirmed} recipients confirmed " \
        "by user #{@user&.id} — #{@basis}"
      )

      Result.new(ok: true, confirmed: confirmed)
    rescue StandardError => e
      Rails.logger.error("[BulkConsentConfirmation] campaign #{@campaign.id}: #{e.class}: #{e.message}")
      Result.new(ok: false, confirmed: 0, error: e.message)
    end
  end
end
