# frozen_string_literal: true

# Customer phone numbers to 303-586-4420 (UsPhone). Only numbers that are 10
# digits, or 11 starting with 1, change; international numbers and ones with
# extensions are left as typed. updated_at is not touched, so "recently
# updated" lists do not fill with every record.
class StandardizeCustomerPhoneNumbers < ActiveRecord::Migration[8.0]
  COLUMNS = { leads: %i[phone co_applicant_phone], contacts: %i[phone], accounts: %i[phone] }.freeze

  def up
    COLUMNS.each do |table, columns|
      columns.each do |column|
        changed = exec_update(UsPhone.backfill_sql(table, column))
        say "#{table}.#{column}: #{changed} reformatted"
      end
    end
  end

  def down; end
end
