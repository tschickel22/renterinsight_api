# frozen_string_literal: true

# Vehicle Documents — per-vehicle document store with 3-tier visibility.
#
# Visibility tiers (default `internal`):
#   - internal: staff only (factory invoices, dealer cost docs, etc.)
#   - customer: visible to the linked buyer via the buyer portal
#   - public:   visible on public/customer-facing inventory surfaces
#
# Why a dedicated table (not agreement_attachments): factory-purchase docs
# travel with the home permanently, must NOT leak to public surfaces, and
# need an enforceable visibility flag. agreement_attachments has no such
# flag and is scoped to agreement lifecycle.
class CreateVehicleDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :vehicle_documents do |t|
      t.references :vehicle, null: false, foreign_key: true, index: true
      t.string  :title,             null: false
      t.string  :category,          null: false, default: 'other'
      t.string  :visibility,        null: false, default: 'internal'
      t.string  :file_url
      t.string  :file_content_type
      t.bigint  :file_size
      t.references :uploaded_by_user, foreign_key: { to_table: :users }, index: true
      t.timestamps
    end

    add_index :vehicle_documents, :visibility
    add_index :vehicle_documents, [:vehicle_id, :visibility]
  end
end
