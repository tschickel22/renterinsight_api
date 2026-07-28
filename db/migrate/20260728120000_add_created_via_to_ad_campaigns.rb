# frozen_string_literal: true

class AddCreatedViaToAdCampaigns < ActiveRecord::Migration[8.0]
  def change
    # The nightly Meta sync pulls in every campaign on the linked ad account,
    # not just the ones launched from the Ad Builder. Record which is which so
    # the Ads tab can say so — existing rows all arrived via sync.
    add_column :ad_campaigns, :created_via, :string, default: 'meta', null: false
  end
end
