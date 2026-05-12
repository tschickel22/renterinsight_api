class AddBookingUrlToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :booking_url, :string
  end
end
