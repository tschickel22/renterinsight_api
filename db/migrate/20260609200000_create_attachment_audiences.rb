# frozen_string_literal: true

# Per-file audience tags for ActiveStorage attachments. Internal/staff always see
# every file; these flags additionally expose a file to the customer (buyer portal)
# and/or the manufacturer (warranty claim). Multi-select: a file can be both.
class CreateAttachmentAudiences < ActiveRecord::Migration[8.0]
  def change
    create_table :attachment_audiences do |t|
      t.bigint :active_storage_attachment_id, null: false
      t.boolean :visible_to_customer, null: false, default: false
      t.boolean :visible_to_manufacturer, null: false, default: false
      t.bigint :tagged_by_id
      t.timestamps
    end
    add_index :attachment_audiences, :active_storage_attachment_id, unique: true,
              name: 'index_attachment_audiences_on_attachment'
  end
end
