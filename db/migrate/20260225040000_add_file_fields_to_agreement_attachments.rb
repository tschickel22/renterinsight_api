class AddFileFieldsToAgreementAttachments < ActiveRecord::Migration[8.0]
  def change
    # Allow file-based attachments (not just entity links)
    add_column :agreement_attachments, :filename, :string
    add_column :agreement_attachments, :file_url, :string
    add_column :agreement_attachments, :file_content_type, :string
    add_column :agreement_attachments, :byte_size, :bigint

    # Make polymorphic columns optional (attachments can be files OR entity links)
    change_column_null :agreement_attachments, :attachable_type, true
    change_column_null :agreement_attachments, :attachable_id, true
  end
end
