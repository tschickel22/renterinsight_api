# frozen_string_literal: true

class RefactorTwilioAccountsForMasterAccount < ActiveRecord::Migration[8.0]
  def up
    # sub_account_sid and auth_token are no longer used now that we buy numbers
    # directly on the master account instead of creating per-company sub-accounts.
    # Make them nullable so existing records don't break, and drop the unique
    # constraint on sub_account_sid (master SID would be the same for all companies).

    # Remove unique index before changing column
    remove_index :twilio_accounts, :sub_account_sid, if_exists: true

    change_column_null :twilio_accounts, :sub_account_sid, true
    change_column_null :twilio_accounts, :auth_token, true

    # Null out any sub_account_sid that equals the master account SID or 'pending'
    execute <<~SQL
      UPDATE twilio_accounts
      SET sub_account_sid = NULL,
          auth_token = NULL
      WHERE sub_account_sid = 'pending'
         OR sub_account_sid IS NOT NULL
    SQL
  end

  def down
    change_column_null :twilio_accounts, :sub_account_sid, false, 'MIGRATED'
    change_column_null :twilio_accounts, :auth_token, false, ''
    add_index :twilio_accounts, :sub_account_sid, unique: true
  end
end
