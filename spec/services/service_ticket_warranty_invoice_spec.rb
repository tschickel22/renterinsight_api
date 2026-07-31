# frozen_string_literal: true

require 'rails_helper'

# Generating a warranty invoice created one unconditionally, so every press of
# Generate minted another WRN for the same work. Ticket 321 collected four
# identical $477.50 invoices in a single afternoon. Now that generating is the
# ordinary way to re-sync a claim from its ticket, this has to be idempotent.
RSpec.describe ServiceTicketInvoiceService, '#generate_warranty_invoice' do
  let(:ticket) do
    instance_double(ServiceTicket, id: 321, company_id: 17, location_id: 45,
                                   has_warranty_items?: true, warranty_total: 477.5)
  end
  let(:claim) { instance_double(WarrantyClaim, manufacturer_id: 35) }
  let(:service) { described_class.new(ticket) }
  let(:relation) { double('relation') }

  before do
    allow(Invoice).to receive(:where).and_return(relation)
    allow(relation).to receive(:where).and_return(relation)
    allow(relation).to receive(:order).and_return(relation)
  end

  context 'when a draft warranty invoice already exists for the claim' do
    let(:items) { double('items', destroy_all: true, sum: 477.5) }
    let(:existing) { double('invoice', status: 'draft', invoice_items: items) }

    before do
      allow(relation).to receive(:first).and_return(existing)
      allow(existing).to receive(:update!)
      allow(existing).to receive(:reload).and_return(existing)
      allow(service).to receive(:create_warranty_invoice_items)
    end

    it 'refreshes it instead of creating a second one' do
      expect(Invoice).not_to receive(:create!)

      expect(service.generate_warranty_invoice(claim)).to eq(existing)
    end

    it 'rebuilds the line items rather than appending to them' do
      expect(items).to receive(:destroy_all)

      service.generate_warranty_invoice(claim)
    end
  end

  context 'when the existing warranty invoice has already been billed' do
    %w[finalized paid partial overdue].each do |status|
      it "leaves a #{status} invoice untouched" do
        existing = double('invoice', status: status)
        allow(relation).to receive(:first).and_return(existing)

        expect(Invoice).not_to receive(:create!)
        expect(existing).not_to receive(:update!)

        expect(service.generate_warranty_invoice(claim)).to eq(existing)
      end
    end
  end

  context 'when no warranty invoice exists yet' do
    it 'creates one' do
      allow(relation).to receive(:first).and_return(nil)
      created = double('invoice', invoice_items: double(sum: 477.5))
      allow(created).to receive(:reload).and_return(created)
      allow(created).to receive(:update!)
      allow(Invoice).to receive(:create!).and_return(created)
      allow(service).to receive(:generate_invoice_number).and_return('WRN-TEST')
      allow(service).to receive(:create_warranty_invoice_items)

      expect(Invoice).to receive(:create!).once

      expect(service.generate_warranty_invoice(claim)).to eq(created)
    end
  end

  it 'does nothing when the ticket has no warranty items' do
    allow(ticket).to receive(:has_warranty_items?).and_return(false)

    expect(Invoice).not_to receive(:create!)
    expect(service.generate_warranty_invoice(claim)).to be_nil
  end
end
