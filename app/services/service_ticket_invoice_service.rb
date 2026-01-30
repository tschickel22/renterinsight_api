# frozen_string_literal: true

class ServiceTicketInvoiceService
  def initialize(service_ticket)
    @ticket = service_ticket
  end
  
  def generate_customer_invoice
    return nil unless @ticket.has_customer_items?
    
    # Get tax rate from company settings or default to 0
    tax_rate = @ticket.company.respond_to?(:tax_rate) ? @ticket.company.tax_rate : 0
    tax_rate ||= 0
    
    invoice = Invoice.create!(
      company_id: @ticket.company_id,
      location_id: @ticket.location_id,
      contact_id: @ticket.contact_id,
      source: @ticket,
      billing_category: 'customer',
      recipient_type: 'Contact',
      recipient_id: @ticket.contact_id,
      invoice_number: generate_invoice_number('INV'),
      invoice_date: Date.current,
      due_date: Date.current + 30.days,
      subtotal: calculate_customer_subtotal,
      tax_rate: tax_rate,
      tax_amount: calculate_customer_tax(tax_rate),
      total: calculate_customer_total(tax_rate),
      amount_due: calculate_customer_total(tax_rate),
      amount_paid: 0,
      status: 'draft',
      notes: "Service Ticket ##{@ticket.id}: #{@ticket.title}"
    )
    
    # Create invoice items from customer parts and labor
    create_customer_invoice_items(invoice)
    
    # Manually recalculate totals from invoice items
    invoice.reload
    subtotal = invoice.invoice_items.sum { |item| item.amount.to_f }
    tax_amount = (subtotal * tax_rate / 100).round(2)
    total = subtotal + tax_amount
    
    invoice.update!(
      subtotal: subtotal,
      tax_amount: tax_amount,
      total: total,
      amount_due: total
    )
    
    invoice
  end
  
  def generate_warranty_invoice(warranty_claim)
    return nil unless @ticket.has_warranty_items?
    
    invoice = Invoice.create!(
      company_id: @ticket.company_id,
      location_id: @ticket.location_id,
      contact_id: nil, # No contact for warranty invoices
      source: warranty_claim,
      billing_category: 'warranty',
      recipient_type: 'Manufacturer',
      recipient_id: warranty_claim.manufacturer_id,
      invoice_number: generate_invoice_number('WRN'),
      invoice_date: Date.current,
      due_date: Date.current + 30.days,
      subtotal: @ticket.warranty_total,
      tax_rate: 0, # No tax on warranty reimbursements
      tax_amount: 0,
      total: @ticket.warranty_total,
      amount_due: @ticket.warranty_total,
      amount_paid: 0,
      status: 'draft',
      notes: "Warranty Claim Reimbursement - Service Ticket ##{@ticket.id}"
    )
    
    # Create invoice items from warranty parts and labor
    create_warranty_invoice_items(invoice)
    
    # Manually recalculate totals from invoice items
    invoice.reload
    subtotal = invoice.invoice_items.sum { |item| item.amount.to_f }
    
    invoice.update!(
      subtotal: subtotal,
      tax_amount: 0,
      total: subtotal,
      amount_due: subtotal
    )
    
    invoice
  end
  
  private
  
  def create_customer_invoice_items(invoice)
    Rails.logger.info "💰 [ServiceTicketInvoiceService] Creating customer invoice items for ticket ##{@ticket.id}"
    
    # Add customer parts
    @ticket.customer_parts.each_with_index do |part, index|
      item = InvoiceItem.create!(
        invoice: invoice,
        description: "Part: #{part['description']}",
        quantity: part['quantity'].to_f,
        rate: part['unitCost'].to_f,
        item_type: 'part'
      )
      
      # CRITICAL: Link to actual Part record for inventory deduction
      part_id = part['partId'] || part['part_id']  # Support both camelCase and snake_case
      
      if part_id.present?
        actual_part = Part.find_by(id: part_id, company_id: @ticket.company_id)
        
        if actual_part
          item.update!(
            itemable_type: 'Part',
            itemable_id: actual_part.id
          )
          Rails.logger.info "✅ [ServiceTicketInvoiceService] Linked invoice item ##{item.id} to Part ##{actual_part.id} (#{actual_part.name})"
        else
          Rails.logger.warn "⚠️ [ServiceTicketInvoiceService] Part ##{part_id} not found for line #{index} - SKU fallback will be attempted"
          # Try to find by SKU as fallback
          if part['partNumber'].present?
            actual_part = Part.find_by(
              company_id: @ticket.company_id,
              sku: part['partNumber']
            )
            
            if actual_part
              item.update!(
                itemable_type: 'Part',
                itemable_id: actual_part.id
              )
              Rails.logger.info "✅ [ServiceTicketInvoiceService] Linked invoice item ##{item.id} to Part ##{actual_part.id} via SKU match (#{actual_part.name})"
            else
              Rails.logger.warn "⚠️ [ServiceTicketInvoiceService] No Part found for SKU '#{part['partNumber']}' - inventory will NOT be deducted"
            end
          end
        end
      else
        Rails.logger.info "ℹ️ [ServiceTicketInvoiceService] Line #{index} has no partId - treating as custom part (no inventory deduction)"
      end
    end
    
    # Add customer labor
    @ticket.customer_labor.each do |labor|
      InvoiceItem.create!(
        invoice: invoice,
        description: "Labor: #{labor['description']}",
        quantity: labor['hours'].to_f,
        rate: labor['rate'].to_f,
        item_type: 'labor'
      )
    end
    
    Rails.logger.info "💰 [ServiceTicketInvoiceService] Created #{@ticket.customer_parts.count} part items and #{@ticket.customer_labor.count} labor items"
  end
  
  def create_warranty_invoice_items(invoice)
    Rails.logger.info "🔧 [ServiceTicketInvoiceService] Creating warranty invoice items for ticket ##{@ticket.id}"
    
    # Add warranty parts
    @ticket.warranty_parts.each_with_index do |part, index|
      item = InvoiceItem.create!(
        invoice: invoice,
        description: "Part: #{part['description']} (Part #: #{part['partNumber']})",
        quantity: part['quantity'].to_f,
        rate: part['unitCost'].to_f,
        item_type: 'part'
      )
      
      # CRITICAL: Link to actual Part record for inventory deduction
      part_id = part['partId'] || part['part_id']  # Support both camelCase and snake_case
      
      if part_id.present?
        actual_part = Part.find_by(id: part_id, company_id: @ticket.company_id)
        
        if actual_part
          item.update!(
            itemable_type: 'Part',
            itemable_id: actual_part.id
          )
          Rails.logger.info "✅ [ServiceTicketInvoiceService] Linked warranty item ##{item.id} to Part ##{actual_part.id} (#{actual_part.name})"
        else
          Rails.logger.warn "⚠️ [ServiceTicketInvoiceService] Part ##{part_id} not found for warranty line #{index} - SKU fallback will be attempted"
          # Try to find by SKU as fallback
          if part['partNumber'].present?
            actual_part = Part.find_by(
              company_id: @ticket.company_id,
              sku: part['partNumber']
            )
            
            if actual_part
              item.update!(
                itemable_type: 'Part',
                itemable_id: actual_part.id
              )
              Rails.logger.info "✅ [ServiceTicketInvoiceService] Linked warranty item ##{item.id} to Part ##{actual_part.id} via SKU match (#{actual_part.name})"
            else
              Rails.logger.warn "⚠️ [ServiceTicketInvoiceService] No Part found for SKU '#{part['partNumber']}' - inventory will NOT be deducted"
            end
          end
        end
      else
        Rails.logger.info "ℹ️ [ServiceTicketInvoiceService] Warranty line #{index} has no partId - treating as custom part (no inventory deduction)"
      end
    end
    
    # Add warranty labor
    @ticket.warranty_labor.each do |labor|
      InvoiceItem.create!(
        invoice: invoice,
        description: "Labor: #{labor['description']}",
        quantity: labor['hours'].to_f,
        rate: labor['rate'].to_f,
        item_type: 'labor'
      )
    end
    
    Rails.logger.info "🔧 [ServiceTicketInvoiceService] Created #{@ticket.warranty_parts.count} warranty part items and #{@ticket.warranty_labor.count} warranty labor items"
  end
  
  def generate_invoice_number(prefix = 'INV')
    timestamp = Time.current.to_i
    "#{prefix}-#{@ticket.company_id}-#{timestamp}"
  end
  
  def calculate_customer_subtotal
    @ticket.customer_total
  end
  
  def calculate_customer_tax(tax_rate = 0)
    subtotal = calculate_customer_subtotal
    (subtotal * tax_rate / 100).round(2)
  end
  
  def calculate_customer_total(tax_rate = 0)
    calculate_customer_subtotal + calculate_customer_tax(tax_rate)
  end
end
