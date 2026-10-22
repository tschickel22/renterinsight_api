# frozen_string_literal: true

# One sign-in for several companies (E68 step 5a). A linked account is a normal
# user row in one company that points at the person's sign-in account.
class AddPrimaryUserToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :primary_user, foreign_key: { to_table: :users }, index: true, null: true
  end
end
