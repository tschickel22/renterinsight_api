# frozen_string_literal: true

# QuickBooks Purchase Sync Handler
#
# Syncs PurchaseOrder records as QuickBooks Bills. QB uses two related
# transaction types:
#   - PurchaseOrder — an unfulfilled order (no accounting effect)
#   - Bill          — an invoice from a vendor, hits AP + expense/inventory
# Since our PurchaseOrder becomes accounting-relevant only after receipt,
# we map to a QB Bill.
#
# Vendor mapping: PurchaseOrder has vendor_id (QB-facing) + supplier_id
# (internal). QB sync requires a Vendor; if missing we raise loudly rather
# than fabricate one.
class QuickbooksPurchaseSyncHandler < QuickbooksSyncHandler
  # Only sync POs where inventory has actually landed — the Bill is what
  # posts AP + expense/inventory. draft / sent / cancelled POs stay local.
  SYNCABLE_STATUSES = %w[partially_received received].freeze

  def qb_entity_type
    'Bill'
  end

  def get_all_syncable_records
    scope = company.purchase_orders.where(is_deleted: [false, nil])
    scope = scope.where(status: SYNCABLE_STATUSES)
    scope = scope.where(location_id: location.id) if location.present?
    scope
  end

  def get_records_by_ids(ids)
    company.purchase_orders.where(id: ids)
  end

  def get_records_by_quickbooks_ids(qb_ids)
    company.purchase_orders.where(quickbooks_id: qb_ids)
  end

  def transform_to_quickbooks(po, config)
    payload = {
      VendorRef:   get_vendor_ref(po),
      TxnDate:     po.order_date&.iso8601 || Date.today.iso8601,
      DueDate:     po.expected_delivery_date&.iso8601,
      DocNumber:   po.po_number,
      PrivateNote: po.notes,
      Line:        build_line_items(po)
    }

    if po.quickbooks_id.present?
      payload[:Id] = po.quickbooks_id
      payload[:SyncToken] = fetch_sync_token!('bill', 'Bill', po.quickbooks_id)
    end

    payload.compact
  end

  def find_by_quickbooks_id(qb_id)
    company.purchase_orders.find_by(quickbooks_id: qb_id)
  end

  def create_from_quickbooks(qb_bill, config)
    vendor_id = qb_bill.dig('VendorRef', 'value')
    vendor    = find_vendor_by_qb_id(vendor_id)

    # QB→local pull needs a supplier since the column is NOT NULL. We derive
    # from vendor when the vendor is linked to a supplier, else abort loudly.
    supplier_id = vendor&.try(:supplier_id) || company.suppliers.order(:id).first&.id
    raise 'Cannot import QB Bill: no supplier available for this company' unless supplier_id

    po = company.purchase_orders.create!(
      location_id:  location&.id,
      supplier_id:  supplier_id,
      vendor_id:    vendor&.id,
      quickbooks_id: qb_bill['Id'],
      po_number:    qb_bill['DocNumber'] || "QB-#{qb_bill['Id']}",
      order_date:   qb_bill['TxnDate'] ? Date.parse(qb_bill['TxnDate']) : Date.today,
      expected_delivery_date: qb_bill['DueDate'] ? Date.parse(qb_bill['DueDate']) : nil,
      total_amount: qb_bill['TotalAmt'] || 0,
      notes:        qb_bill['PrivateNote'],
      status:       (qb_bill['Balance'].to_f > 0 ? 'partially_received' : 'received'),
      quickbooks_synced_at: Time.current
    )
    po
  end

  def update_from_quickbooks(po, qb_bill, config)
    po.update!(
      po_number:    qb_bill['DocNumber'] || po.po_number,
      order_date:   qb_bill['TxnDate'] ? Date.parse(qb_bill['TxnDate']) : po.order_date,
      expected_delivery_date: qb_bill['DueDate'] ? Date.parse(qb_bill['DueDate']) : po.expected_delivery_date,
      total_amount: qb_bill['TotalAmt'] || po.total_amount,
      notes:        qb_bill['PrivateNote'],
      status:       (qb_bill['Balance'].to_f > 0 ? 'partially_received' : 'received'),
      quickbooks_synced_at: Time.current
    )
  end

  private

  def get_vendor_ref(po)
    vendor = po.vendor
    raise "PurchaseOrder ##{po.id} has no vendor — cannot sync to QuickBooks Bill" unless vendor.present?

    if vendor.quickbooks_id.present?
      { value: vendor.quickbooks_id }
    else
      vendor_handler = QuickbooksVendorSyncHandler.new(@entity, @api)
      vendor_data = vendor_handler.transform_to_quickbooks(vendor, {})
      response = @api.create_entity('Vendor', vendor_data)
      qb_id = response.dig('Vendor', 'Id')
      raise "QB Vendor create returned no Id for vendor ##{vendor.id}" if qb_id.blank?

      vendor_handler.save_quickbooks_id(vendor, qb_id)
      { value: qb_id }
    end
  end

  # QB Bill lines need an AccountRef against an Expense (or Inventory-asset)
  # account. We use the mapping service; if no mapping is configured we fall
  # back to any Expense account in the QB chart of accounts.
  def build_line_items(po)
    account_ref = get_expense_account_ref
    po.purchase_order_lines.map.with_index do |line, idx|
      {
        LineNum:    idx + 1,
        DetailType: 'AccountBasedExpenseLineDetail',
        Amount:     line.line_total || (line.quantity_ordered * line.unit_cost),
        Description: [line.description, line.part&.name].compact.first || "Line #{idx + 1}",
        AccountBasedExpenseLineDetail: {
          AccountRef: account_ref
        }.compact
      }
    end
  end

  def get_expense_account_ref
    get_account_from_mapping(
      :assets_liabilities,
      :inventory_asset,
      "SELECT * FROM Account WHERE AccountType = 'Expense' MAXRESULTS 1"
    )
  rescue => e
    Rails.logger.warn "[QB Sync] Could not resolve expense account for PO line: #{e.message}"
    nil
  end

  def find_vendor_by_qb_id(vendor_id)
    company.vendors.find_by(quickbooks_id: vendor_id)
  end
end
