class AddMagicLinkToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :magic_link_token, :string
    add_column :users, :magic_link_expires_at, :datetime
    add_index :users, :magic_link_token, unique: true
  end
end
