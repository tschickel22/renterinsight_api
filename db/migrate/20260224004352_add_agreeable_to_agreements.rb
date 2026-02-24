class AddAgreeableToAgreements < ActiveRecord::Migration[8.0]
  def change
    add_column :agreements, :agreeable_type, :string
    add_column :agreements, :agreeable_id, :bigint
    add_index :agreements, [:agreeable_type, :agreeable_id], name: 'index_agreements_on_agreeable'
  end
end
