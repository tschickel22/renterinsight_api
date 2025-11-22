# frozen_string_literal: true

class AddLocationFieldsToInvitations < ActiveRecord::Migration[8.0]
  def change
    add_column :invitations, :location_ids, :jsonb, default: [], null: false unless column_exists?(:invitations, :location_ids)
    add_column :invitations, :location_role, :string, default: 'location_staff' unless column_exists?(:invitations, :location_role)
    
    add_index :invitations, :location_role unless index_exists?(:invitations, :location_role)
  end
end
