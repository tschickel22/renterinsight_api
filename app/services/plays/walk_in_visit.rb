# frozen_string_literal: true

module Plays
  # Someone who visited the lot. They already met a rep, so the play keeps the
  # lead with that rep and waits a couple of hours before a thank-you, rather
  # than firing "thanks for reaching out" at a person who just shook hands.
  class WalkInVisit < LeadResponsePlay
    KEY = 'walk_in_visit'
    NAME = 'Walk-in visit'
    DESCRIPTION = 'After someone visits the lot, their rep sends a thank-you text and email later that day, gets a ' \
                  'call reminder for the next morning, and follow-up emails keep the visit warm.'

    class << self
      def default_sources
        ['Walk-In']
      end

      # A form for the lot: a tablet at the desk, or a QR code on a sign at a
      # show, so a visitor puts themselves into the play.
      def forms
        [{ name: 'Walk-in Contact', source: 'Walk-In', fields: :contact }]
      end

      def start_tag
        'walk-in'
      end

      def assignment
        :keep_owner
      end

      def default_content
        {
          'first_touch_wait_minutes' => 120,
          'first_text' => {
            'enabled' => true,
            'body' => 'Hi {{first_name}}, it is {{rep_name}} from {{dealership}}. Great meeting you today! Save this ' \
                      'number and text me anytime with questions about the homes you saw.'
          },
          'first_email' => {
            'enabled' => true,
            'subject' => 'Great meeting you today, {{first_name}}',
            'body' => "Hi {{first_name}},\n\nThank you for stopping by {{dealership}} today. It was great showing you " \
                      "around.\n\nIf you would like to see a home again or bring family along, just reply and we will set it up.",
            'booking_line' => 'You can also book your next visit here: {{booking_link}}',
            'signature' => "Talk soon,\n{{rep_name}}\n{{rep_phone}}"
          },
          'call_task' => {
            'enabled' => true, 'subject' => 'Follow up with {{lead_name}} after their visit',
            'due_type' => 'next_day', 'due_minutes' => 60, 'due_time' => '10:00'
          },
          'reply_wait_hours' => 48,
          'follow_up_emails' => [
            { 'day' => 1, 'include_homes' => true, 'subject' => 'The homes you saw at {{dealership}}',
              'body' => "Hi {{first_name}},\n\nThanks again for visiting. Here are a few homes that match what we " \
                        'talked about. Reply if you would like more photos, pricing, or another look in person.' },
            { 'day' => 6, 'include_homes' => false, 'subject' => 'Any questions after your visit, {{first_name}}?',
              'body' => "Hi {{first_name}},\n\nBuying a home is a big decision, and questions usually come up after " \
                        'a visit. Financing, delivery and setup are things we help with every day. Reply with ' \
                        'anything on your mind.' },
            { 'day' => 20, 'include_homes' => true, 'subject' => 'Still thinking it over?',
              'body' => "Hi {{first_name}},\n\nNo pressure at all. New homes arrive on our lot often, so if you tell " \
                        'me what you are looking for, I will let you know when the right one comes in.' }
          ]
        }
      end
    end
  end
end
