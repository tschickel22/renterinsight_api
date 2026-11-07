# frozen_string_literal: true

class SmsRegistration
  # The words we submit when registering an A2P 10DLC texting campaign:
  # description, message flow (opt-in), sample messages and the keyword replies.
  # One place, so the shared pool campaign and every dealer's own campaign at
  # onboarding (backlog E96, phase 4) go out with wording that has already been
  # through review, and a rejection fixed once stays fixed for every dealer.
  #
  # Two kinds:
  # - pool:   DealerTide's shared numbers. Conversational texts about an
  #           inquiry only, NEVER marketing. Consent is the form's inquiry texts
  #           box.
  # - dealer: a dealer's own brand and number, used for both conversations and
  #           marketing. Registered MIXED; the two consents are separate boxes.
  #
  # Rejections this exists to prevent (keep the list growing):
  # - 30913 (2026-11-06, pool): opt-in asked for marketing and non-marketing
  #   texts in one checkbox. Marketing consent must be its own question.
  # - 30886 (2026-11-06, pool): description did not plainly say who sends,
  #   who receives and why; it was mostly the consent wording pasted in.
  # - 30908 / 30882 (2026-11-06, pool): privacy policy and terms URLs missing
  #   (the Twilio CLI 6.2.4 cannot set them; send them over REST).
  #
  # #problems lists anything that would trip those checks; submit only when it
  # is empty.
  class CampaignContent
    KINDS = %w[pool dealer].freeze
    # Words that make a message or a consent sentence marketing. They must not
    # appear in anything that is meant to be conversational only.
    MARKETING_WORDS = /\b(offer|offers|promotion|promotions|promo|sale|sales event|discount|deal of|specials?)\b/i

    attr_reader :kind, :brand, :dealer_name, :legal_name, :example_dealer, :form_url, :screenshot_url

    # dealer_name: the name customers know (DBA). legal_name: as registered.
    # example_dealer: the dealer named in pool samples.
    # form_url / screenshot_url: a live form with the consent boxes, and a
    # public picture of it, for the reviewer.
    def initialize(kind:, brand: Brand.current, dealer_name: nil, legal_name: nil,
                   example_dealer: 'Summit Park Homes', form_url: nil, screenshot_url: nil)
      raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind.to_s)

      @kind = kind.to_s
      @brand = brand
      @dealer_name = dealer_name
      @legal_name = legal_name.presence || dealer_name
      @example_dealer = example_dealer
      @form_url = form_url
      @screenshot_url = screenshot_url
    end

    def pool?
      kind == 'pool'
    end

    def use_case
      'MIXED'
    end

    def platform
      brand.name.to_s
    end

    def sender
      pool? ? example_dealer : dealer_name
    end

    # The consent sentences exactly as the form shows them, with names filled.
    def inquiry_consent
      fill(IntakeForm::DEFAULT_SMS_CONSENT_TEXT, sender)
    end

    def marketing_consent
      fill(IntakeForm.default_marketing_consent_text('manufactured_housing'), sender)
    end

    def description
      if pool?
        "Renter Insight, LLC operates #{platform}, software that manufactured home dealerships use to answer " \
          "customer inquiries. This campaign sends one-to-one conversational text messages from #{platform} to " \
          "consumers who asked a dealership that uses #{platform} about a home and, on that inquiry form, ticked " \
          'a separate box agreeing to texts about their inquiry. The messages answer the consumer\'s questions ' \
          'about the home they asked about, propose and confirm showroom appointment times, send appointment ' \
          'reminders, and connect the consumer with dealership staff. Each message names the dealership. ' \
          'This campaign sends no marketing or promotional messages.'
      else
        "#{legal_name}#{dba_note} is a manufactured home dealership. This campaign sends text messages from " \
          "#{dealer_name} to consumers who asked the dealership about a home and agreed to receive texts. " \
          'Conversational and informational messages answer the consumer\'s questions about their inquiry, ' \
          'offer and confirm showroom appointments and send reminders, and connect them with dealership staff; ' \
          'these go only to consumers who agreed to texts about their inquiry. Marketing messages about homes, ' \
          'offers and events go only to consumers who separately agreed to marketing texts. ' \
          "Messages are sent through #{platform}, the dealership's customer management software, and each names #{dealer_name}."
      end
    end

    def message_flow
      parts = []
      parts << "Consumers opt in on #{pool? ? "a dealership's" : "#{dealer_name}'s"} #{platform}-hosted inquiry form" \
               "#{" (live example: #{form_url}#{screenshot_url ? ", screenshot: #{screenshot_url}" : ''})" if form_url}. " \
               'Below the name, email and phone fields are separate optional checkboxes, each unchecked by default.'
      parts << "The box for texts about the inquiry reads: \"#{inquiry_consent}\""
      if pool?
        parts << "A second, separate box asks for marketing consent. It is optional, it is not required to submit " \
                 'the form, and it does not enable any message on this campaign: only consumers who checked the ' \
                 'inquiry box receive texts here.'
      else
        parts << "A second, separate box for marketing texts reads: \"#{marketing_consent}\" " \
                 'Marketing messages go only to consumers who checked this second box. Neither box is required to ' \
                 'submit the form.'
        parts << 'On Facebook lead forms the same two sentences are two separate optional checkboxes in the ' \
                 'form\'s custom disclaimer. In person or by phone, staff ask before texting and record the ' \
                 'consent on the customer record.'
      end
      parts << "Links to the Privacy Policy (#{brand.privacy_url}) and Terms of Use (#{brand.terms_url}) sit " \
               'directly under the checkboxes. Each opt-in is stored with the wording shown, the page, the time and ' \
               'the IP address. Mobile numbers and opt-in data are never shared with third parties for their marketing.'
      parts.join(' ')
    end

    def message_samples
      who = sample_prefix
      samples = [
        "#{who} Hi Tia, thanks for asking about the Hawthorne. Are you placing it on your own land or in a community? Reply STOP to opt out.",
        "#{who} We have Saturday at 10 AM or 2 PM open to see the Hawthorne at our Denver lot. Which works better for you?",
        "#{who} Reminder: you are set for Saturday at 10 AM at our Denver lot. Reply C to change the time or STOP to opt out.",
        "#{who} I have asked Jordan, our sales consultant, to text you directly about delivery to your land. Reply STOP to opt out."
      ]
      unless pool?
        samples << "#{who} Our fall open house is Saturday 10 AM to 4 PM, with three new floor plans on the lot. Reply STOP to opt out."
      end
      samples
    end

    def opt_in_message
      "#{pool? ? platform : dealer_name}: You will get texts about your home inquiry#{pool? ? ' from the dealership you asked' : ''}. " \
        'Msg frequency varies. Msg & data rates may apply. Reply HELP for help, STOP to opt out.'
    end

    def help_message
      "#{pool? ? "#{platform} texting for home dealerships" : sample_prefix.chomp(':')}. " \
        "Help: #{brand.support_email}. Msg & data rates may apply. Reply STOP to opt out."
    end

    def opt_out_message
      "#{pool? ? platform : dealer_name}: You are unsubscribed and will get no more texts from this number. Reply START to resubscribe."
    end

    # Attributes for Twilio's us_app_to_person create/update (REST names).
    def twilio_attributes
      {
        'Description' => description,
        'MessageFlow' => message_flow,
        'MessageSamples' => message_samples,
        'UsAppToPersonUsecase' => use_case,
        'HasEmbeddedLinks' => true,
        'HasEmbeddedPhone' => true,
        'OptInMessage' => opt_in_message,
        'OptOutMessage' => opt_out_message,
        'HelpMessage' => help_message,
        'OptInKeywords' => %w[START],
        'OptOutKeywords' => %w[STOP STOPALL UNSUBSCRIBE CANCEL END QUIT],
        'HelpKeywords' => %w[HELP INFO],
        'PrivacyPolicyUrl' => brand.privacy_url,
        'TermsAndConditionsUrl' => brand.terms_url
      }
    end

    # What a reviewer would reject. Empty means ready to submit.
    def problems
      list = []
      list << 'no dealer name' if !pool? && dealer_name.blank?
      list << 'no privacy policy URL' if brand.privacy_url.blank?
      list << 'no terms URL' if brand.terms_url.blank?
      list << 'no support email for HELP' if brand.support_email.blank?
      list << 'description over 1024 characters' if description.length > 1024
      list << 'message flow over 2048 characters' if message_flow.length > 2048
      list << '30913: inquiry consent mentions marketing' if inquiry_consent.match?(MARKETING_WORDS)
      list << '30913: marketing consent mentions the inquiry or appointments' if marketing_consent.match?(/inquiry|appointment/i)
      list << '30913: consent sentences are the same' if inquiry_consent == marketing_consent
      %w[STOP HELP rates condition].each do |word|
        list << "consent lacks #{word}" unless inquiry_consent.downcase.include?(word.downcase)
      end
      list << 'pool samples or description read as marketing' if pool? && (message_samples + [description]).any? { |t| t.sub(/no marketing or promotional/i, '').match?(MARKETING_WORDS) }
      list << 'a sample does not name the sender' unless message_samples.all? { |t| t.start_with?(sample_prefix) }
      list << 'no sample shows STOP' unless message_samples.any? { |t| t.include?('STOP') }
      list << 'samples carry placeholders' if message_samples.any? { |t| t.include?('{{') || t.include?('[') }
      list << 'HELP reply does not name the sender' unless help_message.include?(pool? ? platform : dealer_name.to_s)
      list
    end

    private

    # "Summit Park Homes via DealerTide:", or just the name when the dealer is
    # the platform's own company (a "DealerTide via DealerTide" reads as a typo).
    def sample_prefix
      sender.to_s.casecmp?(platform.to_s) ? "#{sender}:" : "#{sender} via #{platform}:"
    end

    def dba_note
      legal_name != dealer_name ? ", doing business as #{dealer_name}," : ''
    end

    def fill(text, company_name)
      text.gsub('{{company}}', company_name.to_s).gsub('{{platform}}', platform)
    end
  end
end
