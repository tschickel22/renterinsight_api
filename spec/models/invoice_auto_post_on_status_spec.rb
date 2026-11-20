# frozen_string_literal: true

require 'rails_helper'

# Marking an invoice sent posts it. The commit-time check read
# previous_changes, which update_status_based_on_payments' row lock (a
# reload) had already emptied, so it never posted.
RSpec.describe Invoice, 'auto-post when the status changes' do
  let(:company) { Company.create!(name: "Post-#{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:contact) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz') }

  before { AccountingSettings.for_company(company).update!(auto_post_invoices: true) }

  def draft
    inv = company.invoices.build(contact: contact, location: location, invoice_date: Date.current, due_date: Date.current + 30,
                                 billing_category: 'customer', tax_rate: 0)
    inv.invoice_items.build(description: 'Home', quantity: 1, rate: 1000, item_type: 'custom', taxable: false, skip_tax: true)
    inv.save!
    inv
  end

  def entries(inv) = company.journal_entries.where(source_entity_type: 'Invoice', source_entity_id: inv.id)

  it 'posts once when a draft is marked sent, and not for the draft' do
    inv = draft
    expect(entries(inv)).to be_empty
    inv.update!(status: 'sent')
    expect(entries(inv).count).to eq(1)
    inv.update!(notes: 'edited after sending')
    expect(entries(inv).count).to eq(1)
  end
end
