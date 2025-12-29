# frozen_string_literal: true

# QuickBooks Invoice Sync Handler
# Syncs invoices as QuickBooks Invoices

class QuickbooksInvoiceSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Invoice'
  end
  
  def get_all_syncable_records
    # Get invoices from company or location
    scope = company.invoices.where(is_deleted: [false, nil])
    
    # Filter by location if needed
    scope = scope.where(location_id: location.id) if location.present?
    
    scope
  end
  
  def get_records_by_ids(ids)
    company.invoices.where(id: ids)
  end
  
  def transform_to_quickbooks(invoice, config)
    # Get or sync customer first
    customer_ref = get_customer_ref(invoice)
    
    # Map invoice to QuickBooks Invoice format
    {
      CustomerRef: customer_ref,
      TxnDate: invoice.invoice_date&.iso8601 || Date.today.iso8601,
      DueDate: invoice.due_date&.iso8601,
      DocNumber: invoice.invoice_number,
      PrivateNote: invoice.notes,
      Line: build_line_items(invoice),
      BillEmail: invoice.contact&.email ? { Address: invoice.contact.email } : nil,
      SalesTermRef: config[:default_terms] ? { value: config[:default_terms] } : nil,
      # Custom fields
      CustomField: [
        {
          DefinitionId: '1',
          Name: 'Invoice ID',
          Type: 'StringType',
          StringValue: invoice.id.to_s
        }
      ].compact
    }.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    company.invoices.find_by(quickbooks_id: qb_id)
  end
  
  def find_or_initialize_from_quickbooks(qb_invoice)
    # First try to find by QB ID
    existing = find_by_quickbooks_id(qb_invoice['Id'])
    return existing if existing
    
    # If not found by QB ID, check if an invoice with this number exists
    # (might have been synced before but QB ID not saved)
    existing = company.invoices.find_by(invoice_number: qb_invoice['DocNumber'])
    
    # If found, update its quickbooks_id to prevent future duplicates
    if existing
      existing.update_column(:quickbooks_id, qb_invoice['Id'])
    end
    
    existing
  end
  
  def create_from_quickbooks(qb_invoice, config)
    # Extract data from QuickBooks Invoice
    customer_id = qb_invoice.dig('CustomerRef', 'value')
    contact = find_or_create_contact_from_qb(customer_id)
    
    # Create invoice with basic info first (without financial totals to avoid callback issues)
    invoice_data = {
      company_id: company.id,
      location_id: location&.id,
      contact_id: contact&.id,
      quickbooks_id: qb_invoice['Id'],
      invoice_number: qb_invoice['DocNumber'],
      invoice_date: qb_invoice['TxnDate'] ? Date.parse(qb_invoice['TxnDate']) : Date.today,
      due_date: qb_invoice['DueDate'] ? Date.parse(qb_invoice['DueDate']) : nil,
      notes: qb_invoice['PrivateNote'],
      status: map_qb_status(qb_invoice),
      quickbooks_synced_at: Time.current
    }
    
    invoice = company.invoices.create!(invoice_data)
    
    # Create line items first
    create_line_items_from_qb(invoice, qb_invoice)
    
    # Now update financial totals using update_columns to skip callbacks
    total_amt = qb_invoice['TotalAmt'].to_f
    tax_amt = qb_invoice['TxnTaxDetail']&.dig('TotalTax').to_f || 0
    subtotal_amt = total_amt - tax_amt
    balance_amt = qb_invoice['Balance'].to_f
    paid_amt = total_amt - balance_amt
    
    invoice.update_columns(
      subtotal: subtotal_amt,
      tax_amount: tax_amt,
      tax_rate: subtotal_amt > 0 ? (tax_amt / subtotal_amt * 100).round(2) : 0,
      total: total_amt,
      amount_paid: paid_amt,
      amount_due: balance_amt,
      updated_at: invoice.updated_at  # Prevent circular sync
    )
    
    invoice
  end
  
  def update_from_quickbooks(invoice, qb_invoice, config)
    # Update contact if changed
    customer_id = qb_invoice.dig('CustomerRef', 'value')
    if customer_id.present?
      contact = find_or_create_contact_from_qb(customer_id)
      invoice.update_column(:contact_id, contact&.id) if contact && invoice.contact_id != contact.id
    end
    
    # Delete existing line items and recreate from QB
    invoice.invoice_items.destroy_all
    create_line_items_from_qb(invoice, qb_invoice)
    
    # Calculate financial totals
    total_amt = qb_invoice['TotalAmt'].to_f
    tax_amt = qb_invoice['TxnTaxDetail']&.dig('TotalTax').to_f || 0
    subtotal_amt = total_amt - tax_amt
    balance_amt = qb_invoice['Balance'].to_f
    paid_amt = total_amt - balance_amt
    
    # Update invoice fields without triggering callbacks
    invoice.update_columns(
      invoice_number: qb_invoice['DocNumber'],
      invoice_date: qb_invoice['TxnDate'] ? Date.parse(qb_invoice['TxnDate']) : invoice.invoice_date,
      due_date: qb_invoice['DueDate'] ? Date.parse(qb_invoice['DueDate']) : invoice.due_date,
      subtotal: subtotal_amt,
      tax_amount: tax_amt,
      tax_rate: subtotal_amt > 0 ? (tax_amt / subtotal_amt * 100).round(2) : 0,
      total: total_amt,
      amount_paid: paid_amt,
      amount_due: balance_amt,
      notes: qb_invoice['PrivateNote'],
      status: map_qb_status(qb_invoice),
      quickbooks_synced_at: Time.current,
      updated_at: invoice.updated_at  # Prevent circular sync
    )
  end
  
  private
  
  def get_customer_ref(invoice)
    # Get customer reference from contact
    contact = invoice.contact
    
    if contact&.quickbooks_id.present?
      { value: contact.quickbooks_id }
    elsif contact.present?
      # Sync contact first
      customer_handler = QuickbooksCustomerSyncHandler.new(@entity, @api)
      customer_data = customer_handler.transform_to_quickbooks(contact, {})
      response = @api.create_entity('Customer', customer_data)
      qb_id = response.dig('Customer', 'Id')
      
      customer_handler.save_quickbooks_id(contact, qb_id)
      
      { value: qb_id }
    else
      raise "Invoice must have a contact to sync to QuickBooks"
    end
  end
  
  def build_line_items(invoice)
    lines = []
    
    # Add invoice items
    invoice.invoice_items.each_with_index do |item, index|
      lines << {
        LineNum: index + 1,
        DetailType: 'SalesItemLineDetail',
        Amount: item.amount || (item.quantity * item.rate),
        Description: item.description,
        SalesItemLineDetail: {
          Qty: item.quantity || 1,
          UnitPrice: item.rate || 0,
          ItemRef: get_item_ref(item)
        }
      }
    end
    
    lines
  end
  
  def get_item_ref(invoice_item)
    # Try to find matching QB Item from listing (Vehicle or MobileHome)
    if invoice_item.listing&.quickbooks_id.present?
      { value: invoice_item.listing.quickbooks_id }
    else
      # Use a default service item or create one
      get_or_create_default_item
    end
  end
  
  def get_or_create_default_item
    # Look for existing "Services" item
    response = @api.search_entities('Item', { Name: 'Services', Type: 'Service' })
    
    if response.dig('QueryResponse', 'Item', 0)
      return { value: response['QueryResponse']['Item'][0]['Id'] }
    end
    
    # Create default service item
    item_data = {
      Name: 'Services',
      Type: 'Service',
      IncomeAccountRef: get_income_account_ref
    }
    
    response = @api.create_entity('Item', item_data)
    { value: response.dig('Item', 'Id') }
    
  rescue => e
    Rails.logger.error "Failed to get/create default item: #{e.message}"
    nil
  end
  
  def get_income_account_ref
    # Get default income account
    response = @api.search_entities('Account', { AccountType: 'Income' })
    
    if response.dig('QueryResponse', 'Account', 0)
      { value: response['QueryResponse']['Account'][0]['Id'] }
    else
      nil
    end
  end
  
  def find_or_create_contact_from_qb(customer_id)
    # Find existing contact
    contact = company.contacts.find_by(quickbooks_id: customer_id)
    return contact if contact
    
    # Fetch from QuickBooks and create
    qb_customer = @api.get_entity('Customer', customer_id)
    
    customer_handler = QuickbooksCustomerSyncHandler.new(@entity, @api)
    customer_handler.create_from_quickbooks(qb_customer['Customer'], {})
    
  rescue => e
    Rails.logger.error "Failed to find/create contact from QB: #{e.message}"
    nil
  end
  
  def create_line_items_from_qb(invoice, qb_invoice)
    # Create line items from QB invoice lines
    lines = qb_invoice['Line'] || []
    
    lines.each do |line|
      next unless line['DetailType'] == 'SalesItemLineDetail'
      
      detail = line['SalesItemLineDetail']
      
      invoice.invoice_items.create!(
        description: line['Description'],
        quantity: detail['Qty'] || 1,
        rate: detail['UnitPrice'] || 0,
        amount: line['Amount'] || 0
      )
    end
  end
  
  def map_qb_status(qb_invoice)
    # Map QuickBooks invoice status to our status
    balance = qb_invoice['Balance'].to_f
    
    if balance <= 0
      'paid'
    elsif qb_invoice['EmailStatus'] == 'EmailSent'
      'sent'
    else
      'draft'
    end
  end
end
