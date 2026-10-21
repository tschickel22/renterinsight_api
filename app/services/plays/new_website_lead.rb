# frozen_string_literal: true

module Plays
  # Someone filled in the contact form on the dealer's website. They are
  # probably still on the site, comparing homes, so the rep answers within
  # minutes, sends their contact card so the call that follows is recognised,
  # and the lead joins the weekly homes email straight away.
  class NewWebsiteLead < LeadResponsePlay
    KEY = 'new_website_lead'
    NAME = 'New website lead'
    DESCRIPTION = 'A lead from your website gets a text and email from their rep right away, the rep\'s contact card ' \
                  'to save, a call within minutes, the weekly homes email, and follow-up emails if they go quiet.'

    # Dealers name their website source themselves; these are the spellings seen.
    WEBSITE_SOURCE = /\bweb\s?(site|form|page|contact)?\b/i

    class << self
      def default_sources
        ['Website']
      end

      # The dealer's own website sources ("Website Contact (easyhomesource.com)",
      # "Web Form"), plus the source this play's form uses.
      def default_sources_for(company)
        return default_sources if company.nil?

        own = company.sources.active.pluck(:name).select { |name| name.to_s.match?(WEBSITE_SOURCE) }
        (own + default_sources).uniq.sort
      end

      # A form with the consent box ticked on, for a site whose contact form has
      # it off. Without consent the play cannot text, however fast it is.
      def forms
        [{ name: 'Website Contact', source: 'Website', fields: :contact }]
      end

      def start_tag
        'website-lead'
      end

      def default_content
        {
          'first_touch_wait_minutes' => 0,
          'weekly_homes_timing' => 'start',
          'first_text' => {
            'enabled' => true,
            'body' => 'Hi {{first_name}}, this is {{rep_name}} with {{dealership}}. Thanks for reaching out on our ' \
                      'website! I will give you a call shortly, or reply here with any questions.'
          },
          'contact_card' => {
            'enabled' => true,
            'body' => 'Save my info so you know it is me when I call: {{contact_card_link}}'
          },
          'first_email' => {
            'enabled' => true,
            'subject' => 'Thanks for contacting {{dealership}}, {{first_name}}',
            'body' => "Hi {{first_name}},\n\nThanks for reaching out through our website. I'm {{rep_name}}, and I " \
                      "will be your point of contact at {{dealership}}.\n\nI will call you soon. In the meantime, " \
                      'reply with the homes you liked or any questions about pricing, financing or delivery.',
            'booking_line' => 'If it is easier, pick a time that works for you: {{booking_link}}',
            'signature' => "Talk soon,\n{{rep_name}}\n{{rep_phone}}\n{{rep_email}}\n\nSave my contact info: {{contact_card_link}}"
          },
          'call_task' => {
            'enabled' => true, 'subject' => 'Call new website lead {{lead_name}}',
            'due_type' => 'minutes', 'due_minutes' => 15, 'due_time' => '10:00'
          },
          'reply_wait_hours' => 24,
          'follow_up_emails' => [
            { 'day' => 1, 'include_homes' => true, 'subject' => 'Homes you might like, {{first_name}}',
              'body' => "Hi {{first_name}},\n\nHere are a few homes on our lot right now that could be a good fit. " \
                        'If one catches your eye, reply and we will set up a time for you to see it in person.' },
            { 'day' => 5, 'include_homes' => false, 'subject' => 'Questions about financing or delivery?',
              'body' => "Hi {{first_name}},\n\nMost buyers have the same few questions: what the monthly payment " \
                        "looks like, how delivery and setup work, and what land is needed. We help with all of it " \
                        "every day.\n\nReply with yours and we will get you answers." },
            { 'day' => 12, 'include_homes' => false, 'subject' => 'Should we keep in touch, {{first_name}}?',
              'body' => "Hi {{first_name}},\n\nI do not want to crowd your inbox. If you are still looking, reply and " \
                        'tell me what you need and I will send options that fit. You will keep getting our weekly ' \
                        'homes email either way, and you can unsubscribe from it anytime.' }
          ]
        }
      end
    end
  end
end
