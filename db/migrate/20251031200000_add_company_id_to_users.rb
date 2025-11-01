# frozen_string_literal: true

class AddCompanyIdToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :company, foreign_key: true, index: true
  end
end
