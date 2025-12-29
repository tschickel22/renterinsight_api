# frozen_string_literal: true
class AddPublicTokenToInvoices < ActiveRecord::Migration[8.0]
  def change
    add_column :invoices, :public_token, :string
    add_index :invoices, :public_token, unique: true
    
    # Generate tokens for existing invoices
    reversible do |dir|
      dir.up do
        Invoice.find_each do |invoice|
          invoice.update_column(:public_token, SecureRandom.urlsafe_base64(32))
        end
      end
    end
  end
end
