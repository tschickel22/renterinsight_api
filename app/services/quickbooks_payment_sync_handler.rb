# frozen_string_literal: true

# QuickBooks Payment Sync Handler
# Syncs payments as QuickBooks Payments

class QuickbooksPaymentSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Payment'
  end
  
  def get_all_syncable_records
    # Get payments from company or location
    scope = company.payments.where(is_deleted: [false, nil])
    
    # Filter by location if needed
    scope = scope.where(location_id: location.id) if location.present?
    
    scope
  end
  
  def get_records_by_ids(ids)
    company.payments.where(id: ids)
  end
  
  def transform_to_quickbooks(payment, config)
    # Get customer reference
    customer_ref = get_customer_ref(payment)
    
    # Map payment to QuickBooks Payment format
    {
      CustomerRef: customer_ref,
      TxnDate: payment.payment_date&.iso8601 || Date.today.iso8601,
      TotalAmt: payment.amount || 0,
      PaymentRefNum: payment.payment_number || payment.id.to_s,
      PrivateNote: payment.notes,
      DepositToAccountRef: get_deposit_account_ref(config),
      Line: build_line_items(payment),
      # Custom fields
      CustomField: [
        {
          DefinitionId: '1',
          Name: 'Payment ID',
          Type: 'StringType',
          StringValue: payment.id.to_s
        }
      ].compact
    }.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    company.payments.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_payment, config)
    # Extract data from QuickBooks Payment
    customer_id = qb_payment.dig('CustomerRef', 'value')
    contact = find_contact_by_qb_id(customer_id)
    
    payment_data = {
      company_id: company.id,
      location_id: location&.id,
      payer_type: 'Contact',
      payer_id: contact&.id,
      quickbooks_id: qb_payment['Id'],
      payment_date: qb_payment['TxnDate'] ? Date.parse(qb_payment['TxnDate']) : Date.today,
      amount: qb_payment['TotalAmt'] || 0,
      payment_type: 'one_time',
      status: 'completed',
      notes: qb_payment['PrivateNote'],
      quickbooks_synced_at: Time.current
    }
    
    company.payments.create!(payment_data)
  end
  
  def update_from_quickbooks(payment, qb_payment, config)
    payment.update!(
      payment_date: qb_payment['TxnDate'] ? Date.parse(qb_payment['TxnDate']) : payment.payment_date,
      amount: qb_payment['TotalAmt'] || payment.amount,
      notes: qb_payment['PrivateNote'],
      quickbooks_synced_at: Time.current
    )
  end
  
  private
  
  def get_customer_ref(payment)
    # Payment uses polymorphic payer association
    contact = if payment.payer_type == 'Contact'
      company.contacts.find_by(id: payment.payer_id)
    elsif payment.respond_to?(:payable) && payment.payable.is_a?(Invoice)
      payment.payable.contact
    else
      nil
    end
    
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
      raise "Payment must have a contact to sync to QuickBooks"
    end
  end
  
  def get_deposit_account_ref(config)
    # Use configured deposit account or find default
    if config[:deposit_to_account]
      { value: config[:deposit_to_account] }
    else
      # Find default "Undeposited Funds" account
      response = @api.search_entities('Account', { Name: 'Undeposited Funds' })
      
      if response.dig('QueryResponse', 'Account', 0)
        { value: response['QueryResponse']['Account'][0]['Id'] }
      else
        nil
      end
    end
  rescue => e
    Rails.logger.error "Failed to get deposit account: #{e.message}"
    nil
  end
  
  def build_line_items(payment)
    lines = []
    
    # If payment is linked to an invoice via payable, add that
    if payment.payable_type == 'Invoice' && payment.payable&.quickbooks_id.present?
      lines << {
        Amount: payment.amount,
        LinkedTxn: [
          {
            TxnId: payment.payable.quickbooks_id,
            TxnType: 'Invoice'
          }
        ]
      }
    else
      # Unapplied payment
      lines << {
        Amount: payment.amount
      }
    end
    
    lines
  end
  
  def find_contact_by_qb_id(customer_id)
    company.contacts.find_by(quickbooks_id: customer_id)
  end
end
