# db/migrate/20251002180100_create_stub_users.rb
class CreateStubUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string :email
      t.string :name
      t.timestamps
    end
  end
end
