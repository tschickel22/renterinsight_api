# frozen_string_literal: true

# SMS opt-in consent for contractors (and other vendors). Contractor-assignment
# notifications send a text only when the contractor has explicitly opted in via
# the Contractor Portal profile page. Defaults false for TCPA safety — existing
# contractors must opt in before they receive any SMS.
class AddSmsOptInToVendors < ActiveRecord::Migration[8.0]
  def change
    add_column :vendors, :sms_opt_in, :boolean, default: false, null: false
  end
end
