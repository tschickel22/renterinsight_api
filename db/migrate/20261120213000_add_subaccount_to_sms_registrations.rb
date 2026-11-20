# frozen_string_literal: true

# Each dealer's own texting is registered in its own Twilio subaccount (Twilio
# support's recommendation, ticket #30449715): their brand, campaign, number
# and opt-outs stay apart from ours and from every other dealer's.
class AddSubaccountToSmsRegistrations < ActiveRecord::Migration[8.0]
  def change
    add_column :sms_registrations, :subaccount_sid, :string
    add_column :sms_registrations, :subaccount_auth_token, :text
  end
end
