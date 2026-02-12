class AddPreviewTokenToWebsites < ActiveRecord::Migration[8.0]
  def change
    add_column :websites, :preview_token, :string
    add_index :websites, :preview_token, unique: true
  end
end
