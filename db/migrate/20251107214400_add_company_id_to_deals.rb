class AddCompanyIdToDeals < ActiveRecord::Migration[8.0]
  def change
    # Check if column exists before adding
    unless column_exists?(:deals, :company_id)
      add_column :deals, :company_id, :integer
      add_index :deals, :company_id
      add_foreign_key :deals, :companies, column: :company_id
    end
  end
end
