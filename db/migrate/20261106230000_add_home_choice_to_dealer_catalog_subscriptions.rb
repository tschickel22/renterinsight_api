# frozen_string_literal: true

# Which of a feed's homes a dealer carries (backlog E94): homes left out, and
# whether a home new to the feed is added at once or held for review.
# reviewed_keys are the homes the dealer has already decided on, so "hold"
# knows which ones are new.
class AddHomeChoiceToDealerCatalogSubscriptions < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_subscriptions, :left_out_keys, :jsonb, default: [], null: false
    add_column :dealer_catalog_subscriptions, :reviewed_keys, :jsonb, default: [], null: false
    add_column :dealer_catalog_subscriptions, :new_homes, :string, default: 'add', null: false
  end
end
