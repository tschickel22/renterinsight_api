# frozen_string_literal: true

class AddLandingPageToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :landing_page, :string, default: 'dashboard', null: false
  end
end
