class AddChannelToCampaigns < ActiveRecord::Migration[8.0]
  def change
    add_column :campaigns, :channel, :string, null: false, default: 'email'
    add_index :campaigns, [:company_id, :channel]
    reversible do |dir|
      dir.up do
        execute "UPDATE campaigns SET channel = 'email' WHERE channel IS NULL"
      end
    end
  end
end
