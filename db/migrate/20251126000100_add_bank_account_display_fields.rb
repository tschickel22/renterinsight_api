class AddBankAccountDisplayFields < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:bank_accounts, :display_last_four)
      add_column :bank_accounts, :display_last_four, :string, limit: 4
    end
    
    unless column_exists?(:bank_accounts, :admin_notes)
      add_column :bank_accounts, :admin_notes, :text
    end
    
    unless column_exists?(:bank_accounts, :locked_at)
      add_column :bank_accounts, :locked_at, :datetime
    end
  end
end
