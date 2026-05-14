# frozen_string_literal: true

class AddDisclaimerToChampionImsRetailers < ActiveRecord::Migration[8.0]
  def change
    add_column :champion_ims_retailers, :custom_retailer_sentence, :text
  end
end
