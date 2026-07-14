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
      # get_entity returns a wrapper keyed by whichever entity was asked
      # for — pick from CamelCase forms of common endpoints so the
      # SyncToken fetch works for invoice / payment / vendor / bill / etc.
      allow(dbl).to receive(:get_entity) do |endpoint, _id|
        key = endpoint.to_s.split('/').last.capitalize
        key = 'CreditMemo' if key == 'Creditmemo'
        { key => { 'SyncToken' => '0' } }
      end
      allow(dbl).to receive(:create_entity).and_return({ 'Item' => { 'Id' => 'QBITEM-1' }, 'Customer' => { 'Id' => 'QBCUST-2' } })
      allow(dbl).to receive(:update_entity).and_return({})
      allow(dbl).to receive(:search_entities).and_return({ 'QueryResponse' => { 'Item' => [{ 'Id' => 'QBITEM-1' }] } })
      allow(dbl).to receive(:query).and_return({ 'QueryResponse' => { 'Account' => [{ 'Id' => 'QBACCT-1', 'Name' => 'Sales' }] } })
      # By default the tenant has NO custom fields configured — handlers
      # should omit the CustomField block. Individual specs can override.
      allow(dbl).to receive(:custom_field_definitions).and_return({})
      allow(dbl).to receive(:custom_field_defined?).and_return(false)
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

  describe 'SyncToken echo on update' do
    it 'InvoiceSync fetches and echoes SyncToken when the invoice already has a quickbooks_id' do
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      handler = QuickbooksInvoiceSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(inv, {})
      expect(payload[:Id]).to eq('QBINV-A')
      expect(payload[:SyncToken]).to eq('0')
      expect(api).to have_received(:get_entity).with('invoice', 'QBINV-A')
    end

    it 'PaymentSync fetches and echoes SyncToken on update' do
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      payment = company.payments.create!(
        amount: 100, payment_type: 'one_time', status: 'completed',
        payer: contact, payment_date: Date.current, gateway_name: 'manual', location: location
      )
      payment.apply_to!(inv, amount: 100)
      payment.update_column(:quickbooks_id, 'QBPMT-42')

      handler = QuickbooksPaymentSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(payment.reload, {})
      expect(payload[:Id]).to eq('QBPMT-42')
      expect(payload[:SyncToken]).to eq('0')
    end

    it 'VendorSync fetches and echoes SyncToken on update' do
      vendor = company.vendors.create!(name: "V-#{SecureRandom.hex(4)}", status: 'active')
      vendor.update_column(:quickbooks_id, 'QBVND-9')

      handler = QuickbooksVendorSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(vendor, {})
      expect(payload[:Id]).to eq('QBVND-9')
      expect(payload[:SyncToken]).to eq('0')
    end
  end

  describe 'CustomField gating' do
    it 'omits CustomField on invoice payload when tenant has none defined' do
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      handler = QuickbooksInvoiceSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(inv, {})
      # Definition '1' not defined in this tenant → CustomField block is nil
      # and stripped by compact.
      expect(payload).not_to have_key(:CustomField)
    end

    it 'includes CustomField when the tenant defines DefinitionId 1 on Invoice' do
      allow(api).to receive(:custom_field_defined?).with('Invoice', '1').and_return(true)
      inv = build_synced_invoice(total: 100, qb_id: 'QBINV-A')
      handler = QuickbooksInvoiceSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(inv, {})
      expect(payload[:CustomField]).to be_present
      expect(payload[:CustomField].first[:StringValue]).to eq(inv.id.to_s)
    end
  end

  describe 'PurchaseOrder → QB Bill mapping' do
    # PurchaseOrder persistence is blocked in this repo's spec setup by a
    # pre-existing schema quirk: Supplier is STI'd on vendors but
    # purchase_orders.supplier_id still FKs the legacy suppliers table, and
    # the belongs_to :supplier validation resolves against vendors. Build
    # in-memory records — the mapper reads attributes and associations,
    # not persisted state.
    let(:vendor) do
      v = company.vendors.new(name: "ACME Vendor #{SecureRandom.hex(3)}", status: 'active')
      v.quickbooks_id = 'QBVND-1'
      v
    end
    let(:part) { company.parts.new(name: 'Widget', sku: "W-#{SecureRandom.hex(3)}", uom: 'ea') }

    def build_po(status: 'received', vendor:, part:)
      po = company.purchase_orders.new(
        location: location,
        vendor: vendor,
        po_number: "PO-#{SecureRandom.hex(3).upcase}",
        order_date: Date.current,
        expected_delivery_date: Date.current + 5.days,
        status: status
      )
      po.purchase_order_lines.new(part: part, line_number: 1, quantity_ordered: 2, unit_cost: 25, line_total: 50, description: 'W')
      po
    end

    it 'builds a Bill payload with VendorRef, DocNumber, and expense line items' do
      handler = QuickbooksPurchaseSyncHandler.new(company, api)
      allow(handler).to receive(:get_expense_account_ref).and_return({ value: 'QBACCT-EXP' })

      po = build_po(status: 'received', vendor: vendor, part: part)
      payload = handler.transform_to_quickbooks(po, {})

      expect(payload[:VendorRef]).to eq({ value: 'QBVND-1' })
      expect(payload[:DocNumber]).to eq(po.po_number)
      expect(payload[:Line].length).to eq(1)
      line = payload[:Line].first
      expect(line[:DetailType]).to eq('AccountBasedExpenseLineDetail')
      expect(line[:Amount]).to eq(50)
      expect(line[:AccountBasedExpenseLineDetail][:AccountRef]).to eq({ value: 'QBACCT-EXP' })
    end

    it 'get_all_syncable_records scope restricts to partially_received/received statuses' do
      handler = QuickbooksPurchaseSyncHandler.new(company, api)
      sql = handler.get_all_syncable_records.to_sql
      expect(sql).to match(/status.*IN.*partially_received.*received/i)
    end

    it 'raises when a PO has no vendor' do
      po = build_po(status: 'received', vendor: vendor, part: part)
      po.vendor = nil
      handler = QuickbooksPurchaseSyncHandler.new(company, api)
      expect { handler.transform_to_quickbooks(po, {}) }
        .to raise_error(/no vendor/)
    end
  end

  describe 'CreditMemo → QB CreditMemo mapping' do
    def build_issued_memo(total: 40, qb_id: nil)
      cm = company.credit_memos.create!(location: location, contact: contact, memo_date: Date.current, reason: 'Return')
      cm.credit_memo_items.create!(description: 'R', quantity: 1, rate: total)
      cm.save!
      cm.issue!
      cm.update_column(:quickbooks_id, qb_id) if qb_id
      cm.reload
    end

    it 'builds CreditMemo payload with CustomerRef and line items' do
      cm = build_issued_memo(total: 40)
      handler = QuickbooksCreditMemoSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(cm, {})

      expect(payload[:CustomerRef]).to eq({ value: 'QBCUST-1' })
      expect(payload[:DocNumber]).to eq(cm.credit_memo_number)
      expect(payload[:Line].length).to eq(1)
      expect(payload[:Line].first[:Amount]).to eq(40)
    end

    it 'fetches SyncToken from creditmemo endpoint when memo already has a quickbooks_id' do
      cm = build_issued_memo(total: 40, qb_id: 'QBCM-9')
      handler = QuickbooksCreditMemoSyncHandler.new(company, api)
      payload = handler.transform_to_quickbooks(cm, {})
      expect(payload[:Id]).to eq('QBCM-9')
      expect(payload[:SyncToken]).to eq('0')
      expect(api).to have_received(:get_entity).with('creditmemo', 'QBCM-9')
    end

    it 'skips draft memos in get_all_syncable_records' do
      _draft = company.credit_memos.create!(location: location, contact: contact, memo_date: Date.current)
      issued = build_issued_memo(total: 20)
      handler = QuickbooksCreditMemoSyncHandler.new(company, api)
      expect(handler.get_all_syncable_records.map(&:id)).to include(issued.id)
      expect(handler.get_all_syncable_records.map(&:status).uniq).not_to include('draft')
    end
  end
end
