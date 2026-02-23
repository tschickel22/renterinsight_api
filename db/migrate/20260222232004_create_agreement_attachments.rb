class CreateAgreementAttachments < ActiveRecord::Migration[8.0]
  def change
    create_table :agreement_attachments do |t|
      t.references :agreement, null: false, foreign_key: true
      t.string :attachable_type, null: false
      t.integer :attachable_id, null: false
      t.integer :attached_by_id
      t.timestamps
    end

    add_index :agreement_attachments, [:attachable_type, :attachable_id], name: 'idx_agr_attachments_polymorphic'
    add_index :agreement_attachments, [:agreement_id, :attachable_type, :attachable_id], unique: true, name: 'idx_agr_attachments_unique'
    add_index :agreement_attachments, :attached_by_id
  end
end
