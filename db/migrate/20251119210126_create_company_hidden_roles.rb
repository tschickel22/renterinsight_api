# frozen_string_literal: true

# Migration: Create company_hidden_roles join table
# Purpose: Track which system roles each company wants to hide from their UI
# This allows per-company visibility without affecting platform-wide system roles

class CreateCompanyHiddenRoles < ActiveRecord::Migration[8.0]
  def change
    create_table :company_hidden_roles do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :role, null: false, foreign_key: true, index: true
      t.timestamps
    end
    
    # Ensure a company can only hide a role once
    add_index :company_hidden_roles, [:company_id, :role_id], unique: true, name: 'index_company_hidden_roles_on_company_and_role'
  end
end
