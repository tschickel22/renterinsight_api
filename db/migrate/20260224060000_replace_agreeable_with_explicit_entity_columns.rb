class ReplaceAgreeableWithExplicitEntityColumns < ActiveRecord::Migration[8.0]
  def change
    # Add explicit entity association columns (all nullable - agreement can relate to any combination)
    add_column :agreements, :contact_id, :bigint
    add_column :agreements, :account_id, :bigint
    add_column :agreements, :deal_id, :bigint

    # Add indexes for efficient lookups
    add_index :agreements, :contact_id, name: 'index_agreements_on_contact_id'
    add_index :agreements, :account_id, name: 'index_agreements_on_account_id'
    add_index :agreements, :deal_id, name: 'index_agreements_on_deal_id'

    # Composite indexes for common queries
    add_index :agreements, [:company_id, :contact_id], name: 'idx_agreements_company_contact'
    add_index :agreements, [:company_id, :account_id], name: 'idx_agreements_company_account'
    add_index :agreements, [:company_id, :deal_id], name: 'idx_agreements_company_deal'

    # Migrate existing polymorphic data to new columns
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE agreements SET contact_id = agreeable_id WHERE agreeable_type = 'Contact';
          UPDATE agreements SET account_id = agreeable_id WHERE agreeable_type = 'Account';
          UPDATE agreements SET deal_id = agreeable_id WHERE agreeable_type = 'Deal';
        SQL
      end
    end

    # Remove old polymorphic columns
    remove_index :agreements, name: 'index_agreements_on_agreeable', if_exists: true
    remove_column :agreements, :agreeable_type, :string
    remove_column :agreements, :agreeable_id, :bigint
  end
end
