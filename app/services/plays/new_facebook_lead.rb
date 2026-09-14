# frozen_string_literal: true

module Plays
  # A lead from a Facebook ad: the fastest first response, because they filled
  # in the form minutes ago and are comparing dealers right now.
  class NewFacebookLead < LeadResponsePlay
    KEY = 'new_facebook_lead'
    NAME = 'New Facebook lead'
    DESCRIPTION = 'A new lead from a Facebook ad gets a text and email from their rep right away, a call within ' \
                  'minutes, and follow-up emails if they go quiet.'

    class << self
      def default_sources
        ['Facebook']
      end

      def forms
        [{ name: 'Facebook Contact', source: 'Facebook', fields: :contact }]
      end

      def default_content
        {
          'first_touch_wait_minutes' => 0,
          'first_text' => {
            'enabled' => true,
            'body' => 'Hi {{first_name}}, this is {{rep_name}} with {{dealership}}. Thanks for your interest on Facebook! ' \
                      'I will give you a call shortly, or reply here with any questions.'
          },
          'first_email' => {
            'enabled' => true,
            'subject' => 'Thanks for reaching out, {{first_name}}',
            'body' => "Hi {{first_name}},\n\nThanks for your interest in {{dealership}} on Facebook. I'm {{rep_name}}, " \
                      "and I will be your point of contact.\n\nI will give you a call soon, or you can reply to this " \
                      'email with any questions.',
            'booking_line' => 'If it is easier, pick a time that works for you: {{booking_link}}',
            'signature' => "Talk soon,\n{{rep_name}}\n{{rep_phone}}"
          },
          'call_task' => {
            'enabled' => true, 'subject' => 'Call new Facebook lead {{lead_name}}',
            'due_type' => 'minutes', 'due_minutes' => 15, 'due_time' => '10:00'
          },
          'reply_wait_hours' => 24,
          'follow_up_emails' => [
            { 'day' => 0, 'include_homes' => false, 'subject' => 'Still looking for the right home, {{first_name}}?',
              'body' => "Hi {{first_name}},\n\nI wanted to follow up on your inquiry with {{dealership}}. Whether you " \
                        "are just starting to look or ready to tour, we are happy to help at your pace.\n\nReply to " \
                        'this email with any questions, or let us know a good time to talk.' },
            { 'day' => 4, 'include_homes' => true, 'subject' => 'A few homes we think you will like',
              'body' => "Hi {{first_name}},\n\nHere are a few homes on our lot right now that could be a good fit. " \
                        'If one catches your eye, reply and we will set up a time for you to see it in person.' },
            { 'day' => 10, 'include_homes' => false, 'subject' => 'Should we keep in touch, {{first_name}}?',
              'body' => "Hi {{first_name}},\n\nI do not want to crowd your inbox. If you are still thinking about a " \
                        'new home, reply and tell me what you are looking for and I will send options that fit. ' \
                        'If now is not the right time, that is completely fine.' }
          ]
        }
      end
    end
  end
end
