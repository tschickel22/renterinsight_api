# frozen_string_literal: true

class AddPortalFieldsToContractors < ActiveRecord::Migration[8.0]
  def change
    add_column :contractors, :portal_access_token, :string
    add_column :contractors, :portal_token_expires_at, :datetime
    add_column :contractors, :last_portal_login_at, :datetime

    add_index :contractors, :portal_access_token, unique: true
  end
end
