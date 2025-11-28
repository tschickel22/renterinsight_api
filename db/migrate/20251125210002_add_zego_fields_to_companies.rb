class AddZegoFieldsToCompanies < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:companies, :external_payments_id)
      add_column :companies, :external_payments_id, :string
      add_index :companies, :external_payments_id
    end
  end
end
