class AddAccountNumberToCompanies < ActiveRecord::Migration[8.0]
  def up
    add_column :companies, :account_number, :string
    add_index  :companies, :account_number, unique: true

    # Backfill existing companies: RI-00019 derived from id
    Company.reset_column_information
    Company.find_each do |c|
      c.update_column(:account_number, format('RI-%05d', c.id))
    end
  end

  def down
    remove_index  :companies, :account_number
    remove_column :companies, :account_number
  end
end
