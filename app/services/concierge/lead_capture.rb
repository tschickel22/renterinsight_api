# frozen_string_literal: true

module Concierge
  # Turns a chat conversation into a lead on the dealer's own intake form.
  #
  # Submits through IntakeSubmission rather than writing a Lead directly, so a
  # chat lead arrives by the same road as a form lead: the dealer's source
  # resolution, their field mappings, their notifications, their duplicate
  # absorption. A second path into the Lead table would be a second set of rules
  # to keep in step, and the first thing to drift would be attribution.
  #
  # Refuses rather than guesses. When the dealer's form asks for something a
  # chat cannot supply, the visitor is sent to the form instead of having a
  # half-filled lead created on their behalf.
  class LeadCapture
    # What a chat exchange can honestly produce. Anything else the dealer marked
    # required is a question we did not ask.
    SATISFIABLE_FIELDS = %w[first_name last_name name full_name email phone notes message comments].freeze

    Result = Struct.new(:status, :message, :lead_id, :form_path, keyword_init: true)

    def initialize(company:, website: nil, form: nil)
      @company = company
      @website = website
      @form = form
    end

    def form
      @form ||= Websites::DefaultLeadForm.for(@company)
    end

    # Whether the conversation can finish in the chat, or has to hand off.
    def available?
      return false if @company.nil?
      return false if form.nil?
      # The dealer switched off automatic lead creation for this form. Honour it.
      return false unless form.auto_create_lead
      # Turnstile cannot be solved in a chat bubble, and a dealer who turned
      # CAPTCHA on did it to stop exactly this kind of unattended submission.
      return false if form.captcha_required

      unsatisfiable_required_fields.empty?
    end

    # Required fields we have no way to ask for in a chat. A dealer who made
    # "trade-in year" mandatory gets their form, not a lead missing it.
    def unsatisfiable_required_fields
      Array(form&.fields).filter_map do |field|
        next unless field.is_a?(Hash)
        next unless truthy?(field['required'] || field[:required])

        mapped = (field['lead_field'] || field['leadField'] || field[:lead_field] || field['name']).to_s
        key = mapped.underscore.parameterize(separator: '_')
        key unless SATISFIABLE_FIELDS.include?(key)
      end
    end

    # Shown before we ask for a phone number, and stored with the lead so there
    # is a record of what the visitor actually agreed to.
    #
    # There is no consent text on intake forms today, so there is nothing to
    # inherit. This is the wording the chat uses until a dealer-level setting
    # exists to override it.
    def consent_text
      "By giving your number you agree that #{dealer_name} may call or text you about your " \
        'enquiry. Message and data rates may apply. Reply STOP to opt out.'
    end

    def dealer_name
      @website&.brand.presence&.dig('company_name').presence || @company&.name.to_s
    end

    # @param visitor [Hash] name, email, phone as the assistant collected them
    # @param intent [String] what they asked for: callback, contact, showing
    # @param transcript [Array<Hash>] the conversation, for the lead's note
    # @param consented [Boolean] whether the consent line was shown and accepted
    def call(visitor:, intent: 'contact', transcript: [], consented: false, request_context: {})
      details = (visitor || {}).symbolize_keys
      name = details[:name].to_s.strip
      email = details[:email].to_s.strip
      phone = details[:phone].to_s.strip

      return Result.new(status: 'incomplete') if name.blank? || (email.blank? && phone.blank?)
      # A number without the consent line having been accepted is not a number
      # we are allowed to have. Keep the lead, drop the phone.
      phone = '' if phone.present? && !consented
      return Result.new(status: 'form_required', form_path: form_path) unless available?

      submission = form.intake_submissions.build(
        data: submission_data(name, email, phone, intent, transcript, consented),
        ip_address: request_context[:ip],
        user_agent: request_context[:user_agent],
        referrer: request_context[:referrer],
        submitted_at: Time.current
      )

      return Result.new(status: 'form_required', form_path: form_path) unless submission.save

      submission.create_lead_from_submission if !submission.lead_created && submission.lead_id.blank?
      submission.reload

      Result.new(status: 'created', lead_id: submission.lead_id,
                 message: form.thank_you_message.presence || default_thanks(intent))
    rescue StandardError => e
      Rails.logger.error("[Concierge::LeadCapture] #{e.class}: #{e.message}")
      Result.new(status: 'form_required', form_path: form_path)
    end

    private

    # Keys chosen to match what IntakeSubmission already auto-detects, so this
    # maps onto a Lead without needing its own branch in that code.
    def submission_data(name, email, phone, intent, transcript, consented)
      data = {
        'name' => name,
        'email' => email.presence,
        'phone' => phone.presence,
        'message' => interest_note(intent, transcript),
        # Attribution. Without it a chat lead is indistinguishable from someone
        # who filled in the form, and the assistant can never be shown to have
        # paid for itself.
        'utm_source' => 'website_assistant',
        'utm_medium' => 'chat'
      }.compact

      if phone.present?
        data['sms_consent'] = consented
        data['sms_consent_text'] = consent_text
        data['sms_consent_at'] = Time.current.iso8601
      end

      data.deep_stringify_keys
    end

    # What they were actually asking about. A salesperson picking this up gets
    # the conversation rather than a name and a blank message.
    def interest_note(intent, transcript)
      # Read by key rather than converted. These arrive as request parameters,
      # and calling to_h on unpermitted ActionController::Parameters raises,
      # which the rescue below turned into a silent hand-off to the form: the
      # lead was lost precisely when the visitor had said the most.
      asked = Array(transcript).filter_map do |turn|
        next unless turn.respond_to?(:[])
        next unless (turn[:role] || turn['role']).to_s == 'user'

        (turn[:content] || turn['content']).to_s.strip.presence
      end.last(4)

      lead_in = case intent.to_s
                when 'callback' then 'Asked for a callback through the website assistant.'
                when 'showing' then 'Asked to book a showing through the website assistant.'
                else 'Asked to be contacted through the website assistant.'
                end

      return lead_in if asked.empty?

      "#{lead_in}\n\nWhat they asked:\n#{asked.map { |line| "- #{line}" }.join("\n")}"
    end

    def default_thanks(intent)
      if intent.to_s == 'callback'
        "Thanks. Someone from #{dealer_name} will call you shortly."
      else
        "Thanks. Someone from #{dealer_name} will be in touch shortly."
      end
    end

    def form_path
      '/contact'
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value).present?
    end
  end
end
