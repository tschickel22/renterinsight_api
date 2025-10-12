class MakeContactAccountIdNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :contacts, :account_id, true
  end
end
