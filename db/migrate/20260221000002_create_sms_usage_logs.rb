class CreateSmsUsageLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :sms_usage_logs do |t|
      t.references :company,          null: false, foreign_key: true
      t.string     :billing_period,   null: false  # format: "YYYY-MM"
      t.string     :direction,        null: false  # inbound / outbound
      t.string     :source,           null: false, default: 'manual'  # manual / sequence / inbound
      t.integer    :message_count,    null: false, default: 1
      t.decimal    :twilio_cost,      precision: 10, scale: 6, default: 0
      t.bigint     :communication_id              # nullable — link back to the Communication record
      t.timestamps
    end

    add_index :sms_usage_logs, [:company_id, :billing_period]
    add_index :sms_usage_logs, :communication_id
  end
end
