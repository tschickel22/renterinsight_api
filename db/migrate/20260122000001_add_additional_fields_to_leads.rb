class AddAdditionalFieldsToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :budget_range, :string
    add_column :leads, :purchase_timeframe, :string
    add_column :leads, :rv_experience, :string
    add_column :leads, :preferred_contact_method, :string
    add_column :leads, :interests_requirements, :text
  end
end
