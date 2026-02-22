class AllowNullCommunicableOnCommunications < ActiveRecord::Migration[7.2]
  def change
    change_column_null :communications, :communicable_type, true
    change_column_null :communications, :communicable_id, true
  end
end
