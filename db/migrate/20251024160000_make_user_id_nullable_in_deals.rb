class MakeUserIdNullableInDeals < ActiveRecord::Migration[8.0]
  def change
    # Remove the NOT NULL constraint from user_id
    # This allows deals to be created without an assigned user
    change_column_null :deals, :user_id, true
  end
end
