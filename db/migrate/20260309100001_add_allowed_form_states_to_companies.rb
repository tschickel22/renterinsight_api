class AddAllowedFormStatesToCompanies < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:companies, :allowed_form_states)
      add_column :companies, :allowed_form_states, :jsonb, default: [], null: false
      add_index :companies, :allowed_form_states, name: 'idx_companies_form_states', using: :gin
    end
  end
end
