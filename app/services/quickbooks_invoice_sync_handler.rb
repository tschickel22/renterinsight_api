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
  
  def create_from_quickbooks(qb_invoice, config)
    # Extract data from QuickBooks Invoice
    customer_id = qb_invoice.dig('CustomerRef', 'value')
    contact = find_or_create_contact_from_qb(customer_id)
    
    invoice_data = {
      company_id: company.id,
      location_id: location&.id,
      contact_id: contact&.id,
      quickbooks_id: qb_invoice['Id'],
      invoice_number: qb_invoice['DocNumber'],
      invoice_date: qb_invoice['TxnDate'] ? Date.parse(qb_invoice['TxnDate']) : Date.today,
      due_date: qb_invoice['DueDate'] ? Date.parse(qb_invoice['DueDate']) : nil,
      subtotal: qb_invoice['TxnTaxDetail']&.dig('TotalTax') || 0,
      tax: qb_invoice['TxnTaxDetail']&.dig('TotalTax') || 0,
      total: qb_invoice['TotalAmt'] || 0,
      notes: qb_invoice['PrivateNote'],
      status: map_qb_status(qb_invoice),
      quickbooks_synced_at: Time.current
    }
    
    invoice = company.invoices.create!(invoice_data)
    
    # Create line items
    create_line_items_from_qb(invoice, qb_invoice)
    
    invoice
  end
  
  def update_from_quickbooks(invoice, qb_invoice, config)
    invoice.update!(
      invoice_number: qb_invoice['DocNumber'],
      invoice_date: qb_invoice['TxnDate'] ? Date.parse(qb_invoice['TxnDate']) : invoice.invoice_date,
      due_date: qb_invoice['DueDate'] ? Date.parse(qb_invoice['DueDate']) : invoice.due_date,
      subtotal: qb_invoice['TxnTaxDetail']&.dig('TotalTax') || 0,
      tax: qb_invoice['TxnTaxDetail']&.dig('TotalTax') || 0,
      total: qb_invoice['TotalAmt'] || 0,
      notes: qb_invoice['PrivateNote'],
      status: map_qb_status(qb_invoice),
      quickbooks_synced_at: Time.current
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
        Amount: item.total || (item.quantity * item.unit_price),
        Description: item.description,
        SalesItemLineDetail: {
          Qty: item.quantity || 1,
          UnitPrice: item.unit_price || 0,
          ItemRef: get_item_ref(item)
        }
      }
    end
    
    lines
  end
  
  def get_item_ref(invoice_item)
    # Try to find matching QB Item
    if invoice_item.vehicle&.quickbooks_id.present?
      { value: invoice_item.vehicle.quickbooks_id }
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
        unit_price: detail['UnitPrice'] || 0,
        total: line['Amount'] || 0
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
