# frozen_string_literal: true

# Account Settings, Signature Block: what the email and text composers add
# when "Add my signature" is checked. Separate from typed_signature, which is
# the e-sign signature on agreements.
class AddSignaturesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :email_signature, :text
    add_column :users, :sms_signature, :string
  end
end
