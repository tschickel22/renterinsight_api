class CreateAgreementReminders < ActiveRecord::Migration[8.0]
  def change
    create_table :agreement_reminders do |t|
      t.references :agreement, null: false, foreign_key: true
      t.references :agreement_signer, null: false, foreign_key: true
      t.datetime :scheduled_at, null: false
      t.datetime :sent_at
      t.string :reminder_type, default: 'auto', null: false  # auto, manual
      t.string :channel, default: 'email', null: false       # email, sms
      t.string :status, default: 'pending', null: false       # pending, sent, failed
      t.text :error_message
      t.timestamps
    end

    add_index :agreement_reminders, [:scheduled_at, :sent_at], name: 'idx_agr_reminders_pending', where: "sent_at IS NULL"
    add_index :agreement_reminders, [:agreement_id, :agreement_signer_id], name: 'idx_agr_reminders_agr_signer'
  end
end
