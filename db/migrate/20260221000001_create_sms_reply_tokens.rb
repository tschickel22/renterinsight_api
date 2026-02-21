class CreateSmsReplyTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :sms_reply_tokens do |t|
      t.string     :token,              null: false
      t.references :company,            null: false, foreign_key: true
      t.bigint     :communication_id,   null: false  # the original outbound communication
      t.bigint     :sender_user_id,     null: false  # user who sent the original SMS
      t.string     :contact_phone,      null: false  # contact's phone number (for display)
      t.datetime   :expires_at,         null: false
      t.datetime   :used_at                          # nullable — tokens can be reused within expiry
      t.timestamps
    end

    add_index :sms_reply_tokens, :token, unique: true
    add_index :sms_reply_tokens, :communication_id
    add_index :sms_reply_tokens, [:company_id, :sender_user_id]
  end
end
