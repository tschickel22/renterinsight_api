# frozen_string_literal: true

class AddCompanyIdToUsers < ActiveRecord::Migration[8.0]
  def change
    # Only add company_id if it doesn't exist
    unless column_exists?(:users, :company_id)
      add_reference :users, :company, null: true, foreign_key: true, index: true
    end
  end
end
