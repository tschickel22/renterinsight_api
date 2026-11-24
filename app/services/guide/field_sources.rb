# frozen_string_literal: true

module Guide
  # Where an agreement field gets its value, in plain words, from the field's
  # key prefix (contact.street comes from the buyer's contact record). Shared
  # by explain_record and my_setup so both say the same thing.
  module FieldSources
    WORDS = {
      'contact' => "the buyer's contact record", 'co_buyer' => "the co-buyer's contact record", 'account' => 'the account',
      'deal' => 'the deal', 'vehicle' => 'the home on the deal', 'home' => 'the home on the deal',
      'company' => 'your company settings', 'location' => 'the location on the agreement', 'signer' => 'the signer, when they sign',
      'date' => 'the date', 'quote' => 'the quote', 'company_logo' => 'your logo'
    }.freeze
    CUSTOM = 'a custom field typed on the agreement'

    module_function

    def describe(key, custom: false)
      return CUSTOM if custom

      WORDS[key.to_s.split('.').first.to_s] || key.to_s
    end
  end
end
