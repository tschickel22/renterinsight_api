# frozen_string_literal: true

require 'rails_helper'

# Exercises the QB payload builders without hitting the real API. We stub
# QuickbooksApiService so the handlers can be instantiated and asked to
# transform records, and we assert the payloads have the right shape.
RSpec.describe 'QB mapper refactor for new accounting shape', type: :service do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'HQ', timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'Buyer', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com", quickbooks_id: 'QBCUST-1') }

  # A test double that satisfies every QB API call the mappers make. The
  # search / create returns are shaped like QB responses (QueryResponse etc.)
  # so the mappers' .dig calls succeed.
  let(:api) do
    instance_double(QuickbooksApiService).tap do |dbl|
      allow(dbl).to receive(:get_entity).and_return({ 'Customer' => { 'SyncToken' => '0' } })
      allow(dbl).to receive(:create_entity).and_return({ 'Item' => { 'Id' => 'QBITEM-1' }, 'Customer' => { 'Id' => 'QBCUST-2' } })
      allow(dbl).to receive(:update_entity).and_return({})
      allow(dbl).to receive(:search_entities).and_return({ 'QueryResponse' => { 'Item' => [{ 'Id' => 'QBITEM-1' }] } })
      allow(dbl).to receive(:query).and_return({ 'QueryResponse' => { 'Account' => [{ 'Id' => 'QBACCT-1', 'Name' => 'Sales' }] } })
    end
  end

  def build_synced_invoice(total: 100, qb_id: 'QBINV-99', taxable: false)
    inv = company.invoices.create!(location: location, contact: contact, invoice_date: Date.current, status: 'draft')
    inv.invoice_items.create!(description: 'L', quantity: 1, rate: total, taxable: taxable)
    inv.save!
    inv.update_column(:quickbooks_id, qb_id)
    inv.reload
  end

  describe 'PaymentSync builds LinkedTxn from payment_applications' do
    it 'emits one Line per application, all pointing to the invoice qbo id' do
      inv_a = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      inv_b = build_synced_invoice(total: 60,  qb_id: 'QBINV-B')

      payment = company.payments.create!(
        amount: 160, payment_type: 'one_time', status: 'completed',
        payer: contact, payment_date: Date.current, gateway_name: 'manual', location: location
      )
      payment.apply_to!(inv_a, amount: 100)
      payment.apply_to!(inv_b, amount: 60)

      handler = QuickbooksPaymentSyncHandler.new(company, api)
      lines = handler.send(:build_line_items, payment.reload)

      expect(lines.length).to eq(2)
      expect(lines.map { |l| l[:Amount] }).to contain_exactly(100, 60)
      linked_ids = lines.map { |l| l[:LinkedTxn].first[:TxnId] }
      expect(linked_ids).to contain_exactly('QBINV-A', 'QBINV-B')
    end

    it 'adds an unlinked line for the unapplied portion of a partially applied payment' do
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      payment = company.payments.create!(
        amount: 150, payment_type: 'one_time', status: 'completed',
        payer: contact, payment_date: Date.current, gateway_name: 'manual', location: location
      )
      payment.apply_to!(inv, amount: 100)

      handler = QuickbooksPaymentSyncHandler.new(company, api)
      lines = handler.send(:build_line_items, payment.reload)

      expect(lines.length).to eq(2)
      applied = lines.find { |l| l[:LinkedTxn].present? }
      unapplied = lines.find { |l| l[:LinkedTxn].nil? }
      expect(applied[:Amount]).to eq(100)
      expect(unapplied[:Amount]).to eq(50)
    end

    it 'refuses to sync when an applied invoice is not yet in QB' do
      inv = company.invoices.create!(location: location, contact: contact, invoice_date: Date.current, status: 'draft')
      inv.invoice_items.create!(description: 'L', quantity: 1, rate: 100)
      inv.save!
      # NOTE: no quickbooks_id set

      payment = company.payments.create!(
        amount: 100, payment_type: 'one_time', status: 'completed',
        payer: contact, payment_date: Date.current, gateway_name: 'manual', location: location
      )
      payment.apply_to!(inv, amount: 100)

      handler = QuickbooksPaymentSyncHandler.new(company, api)
      expect {
        handler.send(:build_line_items, payment.reload)
      }.to raise_error(/not yet synced to QuickBooks/)
    end
  end

  describe 'InvoiceSync includes TxnTaxDetail per TaxCode' do
    it 'emits one TaxLine per TaxCode with the QB TaxRateRef when configured' do
      company.tax_codes.create!(name: 'State 5%', rate: 5, position: 1, qbo_tax_code_id: 'QBTAX-STATE')
      company.tax_codes.create!(name: 'City 2% compound', rate: 2, is_compound: true, position: 2, qbo_tax_code_id: 'QBTAX-CITY')

      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A', taxable: true)

      handler = QuickbooksInvoiceSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(inv, {})

      expect(payload).to have_key(:TxnTaxDetail)
      detail = payload[:TxnTaxDetail]
      expect(detail[:TotalTax]).to eq(7.10)
      expect(detail[:TaxLine].length).to eq(2)

      state_line = detail[:TaxLine].find { |l| l[:TaxLineDetail][:TaxRateRef][:value] == 'QBTAX-STATE' }
      city_line  = detail[:TaxLine].find { |l| l[:TaxLineDetail][:TaxRateRef][:value] == 'QBTAX-CITY' }
      expect(state_line[:Amount]).to eq(5.0)
      expect(state_line[:TaxLineDetail][:NetAmountTaxable]).to eq(100.0)
      expect(city_line[:Amount]).to eq(2.10)
      expect(city_line[:TaxLineDetail][:NetAmountTaxable]).to eq(105.0)
    end

    it 'omits TxnTaxDetail when the invoice has no tax snapshots (legacy path)' do
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A', taxable: false)
      handler = QuickbooksInvoiceSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(inv, {})
      expect(payload).not_to have_key(:TxnTaxDetail)
    end

    it 'omits SalesTermRef when default_terms is blank rather than sending nil' do
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      handler = QuickbooksInvoiceSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(inv, { default_terms: '' })
      expect(payload).not_to have_key(:SalesTermRef)
    end
  end

  describe 'CustomerSync DisplayName uniqueness' do
    it 'always resolves to a guaranteed-unique suffix when :id is asked for' do
      handler = QuickbooksCustomerSyncHandler.new(company, api)
      # No email + same base name still yields uniqueness via RI##{id}
      c_no_email = company.contacts.create!(first_name: 'John', last_name: 'Smith')
      name = handler.send(:build_unique_display_name, c_no_email, :id)
      expect(name).to include("RI##{c_no_email.id}")
    end
  end
end
