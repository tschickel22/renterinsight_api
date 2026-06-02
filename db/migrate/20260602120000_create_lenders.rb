# frozen_string_literal: true

class CreateLenders < ActiveRecord::Migration[8.0]
  def change
    create_table :lenders do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string  :name, null: false
      t.string  :contact_name
      t.string  :phone
      t.string  :email
      t.string  :website
      t.text    :notes
      t.boolean :active, null: false, default: true
      t.boolean :is_deleted, null: false, default: false

      t.timestamps
    end

    add_index :lenders, [:company_id, :name]
  end
end
