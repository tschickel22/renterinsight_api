class AddChampionActionTokenToLeads < ActiveRecord::Migration[7.1]
  def change
    add_column :leads, :champion_action_token, :string
    add_column :leads, :champion_action_token_expires_at, :datetime

    add_index :leads, :champion_action_token, unique: true
  end
end
