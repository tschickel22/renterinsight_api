# frozen_string_literal: true

class AddContactInfoToListings < ActiveRecord::Migration[8.0]
  def change
    add_column :listings, :contact_email, :string
    add_column :listings, :contact_phone, :string
    
    add_index :listings, :contact_email
  end
end
