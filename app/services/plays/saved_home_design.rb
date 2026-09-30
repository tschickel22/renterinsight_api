# frozen_string_literal: true

module Plays
  # A buyer designed a home on the dealer's website and saved it. They have
  # told us exactly which home and which options they want, so the first
  # touch talks about their design and the rep gets a call task within the
  # hour. Leads arrive through the TrueBuild intake form (source TrueBuild).
  class SavedHomeDesign < LeadResponsePlay
    KEY = 'saved_home_design'
    NAME = 'Saved home design'
    DESCRIPTION = 'When a buyer designs a home on your website and saves it, their rep texts and emails them about ' \
                  'their design within minutes, gets a call task due within the hour, and follow-up emails keep the ' \
                  'conversation going until they reply.'

    class << self
      # Only dealers who price homes with TrueBuild have designs to save.
      def offered_to?(company)
        company.present? && (company.dealer_markup_rules.active.exists? || company.dealer_catalog_terms.exists?)
      end

      def default_sources
        [Truebuild::DesignSaver::SOURCE]
      end

      def forms
        [{ name: Truebuild::DesignSaver::FORM_NAME, source: Truebuild::DesignSaver::SOURCE, fields: :contact }]
      end

      def start_tag
        'saved-design'
      end

      def default_content
        {
          'first_touch_wait_minutes' => 2,
          'first_text' => {
            'enabled' => true,
            'body' => 'Hi {{first_name}}, it is {{rep_name}} from {{dealership}}. I just saw the home you designed. ' \
                      'Great choices! When is a good time for a quick call about pricing and delivery?'
          },
          'first_email' => {
            'enabled' => true,
            'subject' => 'The home you designed, {{first_name}}',
            'body' => "Hi {{first_name}},\n\nThanks for designing your home with {{dealership}}. I have your design " \
                      "and options in front of me.\n\nI can walk you through the price, what is included, financing " \
                      'and delivery, or set up a time to see a similar home in person. Just reply to this email.',
            'booking_line' => 'Or pick a time that suits you: {{booking_link}}',
            'signature' => "Talk soon,\n{{rep_name}}\n{{rep_phone}}"
          },
          'call_task' => {
            'enabled' => true, 'subject' => 'Call {{lead_name}} about their saved home design',
            'due_type' => 'minutes', 'due_minutes' => 60, 'due_time' => '10:00'
          },
          'reply_wait_hours' => 24,
          'follow_up_emails' => [
            { 'day' => 2, 'include_homes' => true, 'subject' => 'Homes like the one you designed',
              'body' => "Hi {{first_name}},\n\nHere are a few homes similar to the one you designed. Some are ready " \
                        'sooner than a factory order. Reply if one catches your eye.' },
            { 'day' => 7, 'include_homes' => false, 'subject' => 'Questions about your design, {{first_name}}?',
              'body' => "Hi {{first_name}},\n\nChanging a finish or a floor plan option is easy before an order is " \
                        'placed. Reply with anything you would like to adjust and I will send an updated price.' },
            { 'day' => 21, 'include_homes' => true, 'subject' => 'Still thinking about your new home?',
              'body' => "Hi {{first_name}},\n\nYour design is saved whenever you are ready. If your plans have " \
                        'changed, tell me what you are looking for now and I will help you find it.' }
          ]
        }
      end
    end
  end
end
