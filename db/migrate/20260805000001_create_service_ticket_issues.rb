# frozen_string_literal: true

# Introduces the "issue" (complaint) layer between a service ticket and its
# parts/labor, mirroring how auto and RV DMS platforms structure a repair
# order: the ticket is the visit, each issue is one complaint carrying its own
# parts, labor and pay type (the industry's customer / warranty / internal
# split).
#
# Parts and labor stay as jsonb -- but now hang off the issue, and every row
# gets a stable uuid so billing no longer identifies lines by array position.
class CreateServiceTicketIssues < ActiveRecord::Migration[8.0]
  def change
    create_table :service_ticket_issues do |t|
      t.references :company, null: false, foreign_key: true
      t.references :service_ticket, null: false, foreign_key: true
      t.integer :position, null: false, default: 0

      # The 3 C's. `title` is the short label ("Cracked counters"); complaint is
      # the customer's own words, cause the diagnosis, correction the fix.
      t.string :title, null: false
      t.text :complaint
      t.text :cause
      t.text :correction

      t.string :status, null: false, default: 'open'
      t.string :pay_type, null: false, default: 'warranty'
      t.references :manufacturer, null: true, foreign_key: true

      # Default is vendor-visible; admins opt an issue OUT of the contractor
      # payload rather than opting each one in.
      t.string :visibility, null: false, default: 'external'
      t.boolean :portal_visible, null: false, default: true

      # Pre-authorization. RV OEMs authorize the repair *before* it happens and
      # hand back an auth number plus their own allowed labor time, which
      # routinely differs from what the dealer asked for -- hence both a
      # requested and an approved figure.
      t.string :authorization_number
      t.string :authorization_status, null: false, default: 'not_required'
      t.decimal :requested_hours, precision: 8, scale: 2
      t.decimal :approved_hours, precision: 8, scale: 2
      t.decimal :approved_amount, precision: 12, scale: 2
      t.datetime :authorization_requested_at
      t.datetime :authorization_responded_at
      t.text :authorization_notes

      # Flat-rate operation code from the manufacturer's labor guide. Auto
      # dealers bill the guide's time, not the technician's clock time.
      t.string :labor_op_code

      # Rows carry both an estimate (dealer, before the fix) and an actual
      # (vendor confirms, or dealer finalizes before invoice/warranty).
      #
      # Every amount is nullable on purpose. MH tickets routinely go out to the
      # vendor with no prices at all and come back with the work described but
      # still no numbers -- so "not priced yet" has to be distinguishable from
      # "priced at zero", which a 0.0 default would destroy.
      t.jsonb :parts, null: false, default: []
      t.jsonb :labor, null: false, default: []

      # unpriced -> estimated -> final. Warranty submission and invoicing
      # require `final`; the dealer sets it once numbers are in.
      t.string :pricing_status, null: false, default: 'unpriced'

      # The vendor may answer with their own invoice instead of line items.
      t.string :vendor_invoice_number
      t.decimal :vendor_invoice_amount, precision: 12, scale: 2
      t.datetime :vendor_invoice_received_at

      t.jsonb :custom_field_values, null: false, default: {}

      t.datetime :deleted_at
      t.timestamps
    end

    add_index :service_ticket_issues, %i[service_ticket_id position]
    add_index :service_ticket_issues, %i[company_id status]
    add_index :service_ticket_issues, %i[company_id pay_type]
    add_index :service_ticket_issues, %i[company_id pricing_status]
    add_index :service_ticket_issues, :deleted_at
  end
end
