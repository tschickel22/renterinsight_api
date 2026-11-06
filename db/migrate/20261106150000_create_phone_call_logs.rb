# frozen_string_literal: true

# Calls reported by a dealer's own phone system (3CX first). Every report is kept,
# matched or not, so an unmatched call can be attached later and a resent report
# is recognised by its dedupe key instead of logging the call twice.
class CreatePhoneCallLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :phone_call_logs do |t|
      t.bigint :company_id, null: false
      t.string :provider, null: false, default: '3cx'
      t.string :dedupe_key, null: false
      t.string :call_type            # the provider's word: Inbound, Outbound, Missed, Notanswered
      t.string :direction            # inbound | outbound
      t.string :outcome              # answered | no_answer (LeadActivity::CALL_OUTCOMES)
      t.string :number               # the outside party
      t.string :agent                # extension number
      t.string :agent_name
      t.string :agent_email
      t.bigint :user_id              # the DealerTide user the agent resolved to
      t.datetime :started_at
      t.integer :duration_seconds
      t.string :loggable_type        # Lead | Contact | Account
      t.bigint :loggable_id
      t.string :activity_type        # LeadActivity | ContactActivity | AccountActivity
      t.bigint :activity_id
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :phone_call_logs, %i[company_id dedupe_key], unique: true
    add_index :phone_call_logs, %i[company_id created_at]
    add_index :phone_call_logs, %i[loggable_type loggable_id]
  end
end
