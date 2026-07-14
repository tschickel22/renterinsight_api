# frozen_string_literal: true

# QuickBooks Purchase Sync Handler
# Syncs purchases as QuickBooks Bills.
#
# NOTE: this handler was written against a `Purchase` model that never
# existed in the schema. The real record type is `PurchaseOrder` with
# different columns (po_number, order_date, total_amount) and associations
# (supplier, purchase_order_lines). Until the handler is rewritten,
# ENTITY_TYPES in QuickbooksSyncService omits 'purchases' so it won't be
# invoked. If a caller instantiates it directly, methods raise loudly
# instead of silently returning an empty scope that looks successful.
class QuickbooksPurchaseSyncHandler < QuickbooksSyncHandler
  NOT_IMPLEMENTED = 'QuickbooksPurchaseSyncHandler needs a rewrite against PurchaseOrder — see class docs.'

  def qb_entity_type
    'Bill'
  end

  def get_all_syncable_records
    raise NotImplementedError, NOT_IMPLEMENTED
  end

  def get_records_by_ids(_ids)
    raise NotImplementedError, NOT_IMPLEMENTED
  end
  
  def transform_to_quickbooks(purchase, config)
    {
      VendorRef: get_vendor_ref(purchase),
      TxnDate: purchase.purchase_date&.iso8601 || Date.today.iso8601,
      DueDate: purchase.due_date&.iso8601,
      DocNumber: purchase.purchase_number,
      PrivateNote: purchase.notes,
      Line: build_line_items(purchase)
    }.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    return nil unless defined?(Purchase)
    company.purchases.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_bill, config)
    return nil unless defined?(Purchase)
    
    vendor_id = qb_bill.dig('VendorRef', 'value')
    vendor = find_vendor_by_qb_id(vendor_id)
    
    purchase_data = {
      company_id: company.id,
      location_id: location&.id,
      vendor_id: vendor&.id,
      quickbooks_id: qb_bill['Id'],
      purchase_number: qb_bill['DocNumber'],
      purchase_date: qb_bill['TxnDate'] ? Date.parse(qb_bill['TxnDate']) : Date.today,
      due_date: qb_bill['DueDate'] ? Date.parse(qb_bill['DueDate']) : nil,
      total: qb_bill['TotalAmt'] || 0,
      notes: qb_bill['PrivateNote'],
      status: qb_bill['Balance'].to_f > 0 ? 'unpaid' : 'paid',
      quickbooks_synced_at: Time.current
    }
    
    company.purchases.create!(purchase_data)
  end
  
  def update_from_quickbooks(purchase, qb_bill, config)
    purchase.update!(
      purchase_number: qb_bill['DocNumber'],
      purchase_date: qb_bill['TxnDate'] ? Date.parse(qb_bill['TxnDate']) : purchase.purchase_date,
      due_date: qb_bill['DueDate'] ? Date.parse(qb_bill['DueDate']) : purchase.due_date,
      total: qb_bill['TotalAmt'] || purchase.total,
      notes: qb_bill['PrivateNote'],
      status: qb_bill['Balance'].to_f > 0 ? 'unpaid' : 'paid',
      quickbooks_synced_at: Time.current
    )
  end
  
  private
  
  def get_vendor_ref(purchase)
    vendor = purchase.vendor
    
    if vendor&.quickbooks_id.present?
      { value: vendor.quickbooks_id }
    elsif vendor.present?
      # Sync vendor first
      vendor_handler = QuickbooksVendorSyncHandler.new(@entity, @api)
      vendor_data = vendor_handler.transform_to_quickbooks(vendor, {})
      response = @api.create_entity('Vendor', vendor_data)
      qb_id = response.dig('Vendor', 'Id')
      
      vendor_handler.save_quickbooks_id(vendor, qb_id)
      
      { value: qb_id }
    else
      raise "Purchase must have a vendor to sync to QuickBooks"
    end
  end
  
  def build_line_items(purchase)
    lines = []
    
    # Add purchase items
    purchase.purchase_items.each_with_index do |item, index|
      lines << {
        LineNum: index + 1,
        DetailType: 'AccountBasedExpenseLineDetail',
        Amount: item.total || (item.quantity * item.unit_price),
        Description: item.description,
        AccountBasedExpenseLineDetail: {
          AccountRef: get_expense_account_ref
        }
      }
    end
    
    lines
  end
  
  def get_expense_account_ref
    # Find default expense account
    response = @api.search_entities('Account', { AccountType: 'Expense' })
    
    if response.dig('QueryResponse', 'Account', 0)
      { value: response['QueryResponse']['Account'][0]['Id'] }
    else
      nil
    end
  rescue => e
    Rails.logger.error "Failed to get expense account: #{e.message}"
    nil
  end
  
  def find_vendor_by_qb_id(vendor_id)
    return nil unless defined?(Vendor)
    company.vendors.find_by(quickbooks_id: vendor_id)
  end
end
