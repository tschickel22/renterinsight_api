# frozen_string_literal: true

class AddPublicTokenToQuotes < ActiveRecord::Migration[7.0]
  def change
    add_column :quotes, :public_token, :string
    add_index :quotes, :public_token, unique: true
  end
end
