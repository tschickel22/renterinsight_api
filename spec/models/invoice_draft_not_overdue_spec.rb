# frozen_string_literal: true

require 'rails_helper'

# A draft is not owed yet. A past-due draft used to turn 'overdue' on its
# first save, and 'overdue' auto-posts, so it was booked before anyone issued it.
RSpec.describe Invoice, 'past-due drafts' do
  let(:company) { Company.create!(name: "Draft-#{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:contact) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz') }

  def build(status: nil)
    inv = company.invoices.build(contact: contact, location: location, invoice_date: Date.current - 40,
                                 due_date: Date.current - 10, billing_category: 'customer', tax_rate: 0, status: status)
    inv.invoice_items.build(description: 'Home', quantity: 1, rate: 100, item_type: 'custom', taxable: false, skip_tax: true)
    inv.save!
    inv.reload
  end

  it 'stays a draft, is not overdue and is not posted' do
    AccountingSettings.for_company(company).update!(auto_post_invoices: true)
    inv = build
    inv.update!(notes: 'edited')
    expect(inv.reload.status).to eq('draft')
    expect(inv.overdue?).to be(false)
    expect(company.invoices.overdue).not_to include(inv)
    expect(inv.should_auto_post_to_accounting?).to be(false)
  end

  it 'still marks a sent invoice overdue once its due date passes' do
    inv = build(status: 'sent')
    expect(inv.status).to eq('overdue')
    expect(company.invoices.overdue).to include(inv)
  end
end
