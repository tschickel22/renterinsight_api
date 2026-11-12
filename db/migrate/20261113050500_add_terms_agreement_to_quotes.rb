# frozen_string_literal: true

# A buyer accepting a quote that carries terms and conditions now has to tick
# that they agree. Keep the time and the exact wording they agreed to, because
# the dealer can edit the quote's terms afterwards.
class AddTermsAgreementToQuotes < ActiveRecord::Migration[8.0]
  def change
    add_column :quotes, :terms_agreed_at, :datetime
    add_column :quotes, :agreed_terms, :text
  end
end
