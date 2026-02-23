class CreateAgreementSigners < ActiveRecord::Migration[8.0]
  def change
    create_table :agreement_signers do |t|
      t.references :agreement, null: false, foreign_key: true
      t.string :role, default: 'signer', null: false  # signer, counter_signer, preparer, cc
      t.integer :signing_order, default: 1, null: false
      t.string :signable_type   # Polymorphic: Contact, Supplier, User, or nil for ad-hoc
      t.integer :signable_id
      t.string :name, null: false
      t.string :email, null: false
      t.string :phone            # For SMS notifications
      t.string :access_token, null: false
      t.string :status, default: 'pending', null: false  # pending, viewed, signed, declined
      t.datetime :signed_at
      t.datetime :viewed_at
      t.datetime :declined_at
      t.string :signature_url    # S3 URL for signature image (PNG)
      t.string :signature_method # draw, type, upload
      t.string :initials_url     # S3 URL for initials image (PNG)
      t.string :initials_method  # draw, type
      t.string :typed_signature  # Text if method is 'type'
      t.string :typed_initials   # Text if method is 'type'
      t.string :signature_font   # Font used for typed signature
      t.string :ip_address
      t.text :user_agent
      t.text :decline_reason
      t.string :signature_hash   # SHA-256 of signature data + timestamp for integrity
      t.timestamps
    end

    add_index :agreement_signers, [:agreement_id, :role], name: 'idx_agr_signers_agreement_role'
    add_index :agreement_signers, :access_token, unique: true
    add_index :agreement_signers, [:signable_type, :signable_id], name: 'idx_agr_signers_polymorphic'
    add_index :agreement_signers, :status
    add_index :agreement_signers, :email
  end
end
