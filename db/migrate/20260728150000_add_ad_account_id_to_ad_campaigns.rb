# frozen_string_literal: true

class AddAdAccountIdToAdCampaigns < ActiveRecord::Migration[8.0]
  def change
    # Which Meta ad account a campaign was pulled from. Without this, switching
    # the linked ad account left the previous account's campaigns in the list
    # forever — the sync only ever upserts, it never retires rows.
    #
    # Deliberately left null on existing rows: they came from whichever account
    # was linked at the time and we can't know which. The next sync stamps the
    # ones that are really there; the rest stay hidden.
    add_column :ad_campaigns, :ad_account_id, :string
    add_index  :ad_campaigns, %i[company_id ad_account_id]
  end
end
