class AllowNullFromIdentityIdOnCampaigns < ActiveRecord::Migration[8.0]
  # Campaigns now support from_identity_type = 'Owner', which resolves the
  # sender per-recipient at send time (using each enrollment recipient's
  # owner_id). There's no ID to store on the campaign row itself, so this
  # column has to be nullable for Owner-mode campaigns. Non-Owner campaigns
  # keep the ID as before — a Campaign model validation enforces presence
  # for User/Location/Company identity types.
  def change
    change_column_null :campaigns, :from_identity_id, true
  end
end
