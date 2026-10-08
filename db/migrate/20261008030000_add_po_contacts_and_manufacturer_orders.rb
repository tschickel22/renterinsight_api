# frozen_string_literal: true

# A manufacturer has up to three contacts: the rep, where purchase orders go,
# and where warranty claims go (backlog E51). The PO contact is new; when it
# is blank, POs go to the rep. A purchase order can be placed with a
# manufacturer (its supplier record is made for it, so the factory invoice can
# be entered as a bill) and emailed to that PO contact.
class AddPoContactsAndManufacturerOrders < ActiveRecord::Migration[8.0]
  def change
    # The factory default (for a dealer's own manufacturer) and the dealer's override.
    add_column :manufacturers, :po_email, :string
    add_column :manufacturers, :po_contact_name, :string
    add_column :company_manufacturers, :po_email, :string
    add_column :company_manufacturers, :po_contact_name, :string

    add_reference :purchase_orders, :manufacturer, foreign_key: true
    add_column :purchase_orders, :emailed_at, :datetime
    add_column :purchase_orders, :emailed_to, :string
  end
end
