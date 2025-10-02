# db/migrate/20251002xxxxxx_create_users_stub.rb
class CreateUsersStub < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :name
      t.string :email
      t.timestamps
    end
  end
end
