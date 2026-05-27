class AddSourceCreatedAtToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :source_created_at, :datetime
    add_index :leads, :source_created_at
  end
end
