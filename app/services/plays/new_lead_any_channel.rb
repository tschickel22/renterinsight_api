# frozen_string_literal: true

module Plays
  # The first starter play, replaced by per-channel plays (New Facebook lead,
  # Walk-in visit) because one message cannot suit every channel. Kept, hidden,
  # so an install that is already on can be seen, customized and turned off.
  class NewLeadAnyChannel < LeadResponsePlay
    KEY = 'new_lead_any_channel'
    NAME = 'New lead, any channel'
    DESCRIPTION = 'Replaced by the per-channel plays. Turn this off and set up the plays for your channels instead.'

    CHANNEL_SOURCES = {
      'website' => 'Website', 'prequalification' => 'Pre-Qualification', 'google' => 'Google', 'facebook' => 'Facebook'
    }.freeze

    class << self
      def hidden?
        true
      end

      def default_sources
        CHANNEL_SOURCES.values
      end

      def start_tag
        'follow-up'
      end

      # This play stored channel keys rather than source names.
      def legacy_sources(stored)
        Array(stored['channels']).filter_map { |key| CHANNEL_SOURCES[key.to_s] }.presence || default_sources
      end

      def default_content
        Plays::NewFacebookLead.default_content.deep_dup.tap do |content|
          content['first_text']['body'] = 'Hi {{first_name}}, this is {{rep_name}} with {{dealership}}. Thanks for ' \
                                          'reaching out! I will give you a call shortly, or reply here with any questions.'
          content['first_email']['body'] = "Hi {{first_name}},\n\nThanks for contacting {{dealership}}. I'm " \
                                           "{{rep_name}}, and I will be your point of contact.\n\nI will give you a " \
                                           'call soon, or you can reply to this email with any questions.'
          content['call_task']['subject'] = 'Call new lead {{lead_name}}'
        end
      end
    end
  end
end
