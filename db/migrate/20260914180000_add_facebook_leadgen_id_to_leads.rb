class AddFacebookLeadgenIdToLeads < ActiveRecord::Migration[8.0]
  # Meta can deliver the same lead more than once, and the id it assigns is
  # what tells a second delivery apart from a second person. Mirrors
  # champion_salesforce_id. Built concurrently: leads is a busy table.
  disable_ddl_transaction!

  def change
    add_column :leads, :facebook_leadgen_id, :string
    add_index :leads, [:company_id, :facebook_leadgen_id],
              unique: true, name: 'idx_leads_company_facebook_leadgen_id', algorithm: :concurrently
  end
end
