# frozen_string_literal: true

require 'rails_helper'

# The warranty side was made idempotent because re-generating minted duplicate
# WRN invoices. The customer side had the same defect and still created a fresh
# INV on every press — which now matters more, because a dealer who generates
# again to pick up a missing warranty invoice would otherwise double-bill the
# customer as a side effect.
RSpec.describe ServiceTicketInvoiceService, '#generate_customer_invoice' do
  let(:company) { double('company', tax_rate: 0) }
  let(:ticket) do
    instance_double(ServiceTicket, id: 321, company_id: 17, location_id: 45, contact_id: 88,
                                   title: 'Roof leak', company: company, has_customer_items?: true)
  end
  let(:service) { described_class.new(ticket) }
  let(:relation) { double('relation') }

  before do
    allow(Invoice).to receive(:where).and_return(relation)
    allow(relation).to receive(:where).and_return(relation)
    allow(relation).to receive(:order).and_return(relation)
  end

  context 'when a draft customer invoice already exists for the ticket' do
    let(:items) { double('items', destroy_all: true, sum: 250.0) }
    let(:existing) { double('invoice', status: 'draft', invoice_items: items) }

    before do
      allow(relation).to receive(:first).and_return(existing)
      allow(existing).to receive(:update!)
      allow(existing).to receive(:reload).and_return(existing)
      allow(service).to receive(:create_customer_invoice_items)
    end

    it 'refreshes it instead of creating a second one' do
      expect(Invoice).not_to receive(:create!)

      expect(service.generate_customer_invoice).to eq(existing)
    end

    it 'rebuilds the line items rather than appending to them' do
      expect(items).to receive(:destroy_all)

      service.generate_customer_invoice
    end
  end

  context 'when the existing customer invoice has already been billed' do
    %w[finalized sent paid partial overdue].each do |status|
      it "leaves a #{status} invoice untouched" do
        existing = double('invoice', status: status)
        allow(relation).to receive(:first).and_return(existing)

        expect(Invoice).not_to receive(:create!)
        expect(existing).not_to receive(:update!)

        expect(service.generate_customer_invoice).to eq(existing)
      end
    end
  end

  context 'when no customer invoice exists yet' do
    it 'creates one' do
      allow(relation).to receive(:first).and_return(nil)
      created = double('invoice', invoice_items: double(sum: 250.0))
      allow(created).to receive(:reload).and_return(created)
      allow(created).to receive(:update!)
      allow(Invoice).to receive(:create!).and_return(created)
      allow(service).to receive(:generate_invoice_number).and_return('INV-TEST')
      allow(service).to receive(:create_customer_invoice_items)
      allow(service).to receive(:calculate_customer_subtotal).and_return(250.0)
      allow(service).to receive(:calculate_customer_tax).and_return(0)
      allow(service).to receive(:calculate_customer_total).and_return(250.0)

      expect(Invoice).to receive(:create!).once

      expect(service.generate_customer_invoice).to eq(created)
    end
  end

  it 'does nothing when the ticket has no customer items' do
    allow(ticket).to receive(:has_customer_items?).and_return(false)

    expect(Invoice).not_to receive(:create!)
    expect(service.generate_customer_invoice).to be_nil
  end
end
