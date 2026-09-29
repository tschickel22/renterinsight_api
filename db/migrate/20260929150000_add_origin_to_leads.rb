# frozen_string_literal: true

# Which channel created a lead, so the work queue can surface every new
# inbound one (intake form, partner API, Facebook Lead Ads) until a rep makes
# first contact. Source is the dealer's marketing label and can be anything;
# this is the system's own record of how the lead arrived.
#
# Backfills what can be proven: a Facebook leadgen id, or an intake submission
# that created the lead. Partner API leads left no trace, so older ones stay
# blank.
class AddOriginToLeads < ActiveRecord::Migration[8.0]
  def up
    add_column :leads, :origin, :string
    add_index :leads, [:company_id, :origin]

    execute <<~SQL.squish
      UPDATE leads SET origin = 'facebook_lead_ads'
      WHERE facebook_leadgen_id IS NOT NULL AND origin IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE leads SET origin = 'intake_form'
      WHERE origin IS NULL
        AND EXISTS (SELECT 1 FROM intake_submissions s WHERE s.lead_id = leads.id)
    SQL
  end

  def down
    remove_index :leads, [:company_id, :origin]
    remove_column :leads, :origin
  end
end
