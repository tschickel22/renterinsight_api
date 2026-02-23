class CreateAgreementAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :agreement_audit_logs do |t|
      t.references :agreement, null: false, foreign_key: true
      t.references :agreement_signer, foreign_key: true, null: true
      t.string :action, null: false
      t.string :ip_address
      t.text :user_agent
      t.string :geolocation
      t.string :performed_by_type   # Polymorphic: User or AgreementSigner
      t.integer :performed_by_id
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :agreement_audit_logs, [:agreement_id, :action], name: 'idx_agr_audit_agreement_action'
    add_index :agreement_audit_logs, [:agreement_id, :created_at], name: 'idx_agr_audit_agreement_time'
    add_index :agreement_audit_logs, [:performed_by_type, :performed_by_id], name: 'idx_agr_audit_performer'
  end
end
