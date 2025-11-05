# frozen_string_literal: true

class AddInvitationIdToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :invitation, foreign_key: true, null: true
    add_index :users, [:email, :invitation_id], unique: false
  end
end
