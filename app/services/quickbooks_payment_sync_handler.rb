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
    scope = scope.where(location_id: location.id) if location.present?

    # Only sync payments where every applied invoice has already been
    # pushed to QB. The old join went through payments.payable_id (now
    # legacy); we now inspect payment_applications and skip payments that
    # apply to any not-yet-synced invoice. Payments with no applications
    # (pure unapplied credit) are still syncable — QB accepts them.
    ids_with_unsynced_applications = PaymentApplication
      .where(payment_id: scope.select(:id), applicable_type: 'Invoice')
      .joins("INNER JOIN invoices ON invoices.id = payment_applications.applicable_id")
      .where(invoices: { quickbooks_id: nil })
      .distinct
      .pluck(:payment_id)

    scope.where.not(id: ids_with_unsynced_applications)
  end
  
  def get_records_by_ids(ids)
    company.payments.where(id: ids)
  end
  
  # PERFORMANCE: Batch load payments by QuickBooks IDs (1 query instead of N)
  def get_records_by_quickbooks_ids(qb_ids)
    company.payments.where(quickbooks_id: qb_ids)
  end
  
  def transform_to_quickbooks(payment, config)
    customer_ref = get_customer_ref(payment)

    payload = {
      CustomerRef: customer_ref,
      TxnDate: payment.payment_date&.iso8601 || Date.today.iso8601,
      TotalAmt: payment.amount || 0,
      PaymentRefNum: payment.payment_number || payment.id.to_s,
      PrivateNote: payment.notes,
      DepositToAccountRef: get_deposit_account_ref(config),
      Line: build_line_items(payment),
      # Custom fields — only send if the connected QB realm has defined
      # DefinitionId '1' on Payment transactions; otherwise leave off.
      CustomField: (@api.custom_field_defined?('Payment', '1') ? [
        {
          DefinitionId: '1',
          Name: 'Payment ID',
          Type: 'StringType',
          StringValue: payment.id.to_s
        }
      ] : nil)
    }

    # For updates, echo current SyncToken back — QB rejects updates without it.
    if payment.quickbooks_id.present?
      payload[:Id] = payment.quickbooks_id
      payload[:SyncToken] = fetch_sync_token!('payment', 'Payment', payment.quickbooks_id)
    end

    payload.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    company.payments.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_payment, config)
    # Extract data from QuickBooks Payment
    customer_id = qb_payment.dig('CustomerRef', 'value')
    contact = find_contact_by_qb_id(customer_id)
    
    # Landing location — same waterfall as invoice/customer/inventory so
    # payments stay in the location where the user was working.
    resolved_location_id = location&.id ||
      (Current.location_filtered? ? Current.location_id : nil) ||
      company.locations.where(active: true, is_deleted: [false, nil]).order(:id).first&.id

    payment_data = {
      company_id: company.id,
      location_id: resolved_location_id,
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
    # Contact resolution: payer first, then fall back to the contact on any
    # invoice this payment applies to. The old code looked at payment.payable
    # (legacy 1:1 link); now we walk payment_applications.
    contact = if payment.payer_type == 'Contact'
      company.contacts.find_by(id: payment.payer_id)
    else
      applied_invoice = payment.payment_applications
                               .where(applicable_type: 'Invoice')
                               .joins("INNER JOIN invoices ON invoices.id = payment_applications.applicable_id")
                               .first&.applicable
      applied_invoice&.contact
    end

    if contact&.quickbooks_id.present?
      { value: contact.quickbooks_id }
    elsif contact.present?
      # Sync contact first
      customer_handler = QuickbooksCustomerSyncHandler.new(@entity, @api)
      customer_data = customer_handler.transform_to_quickbooks(contact, {})
      response = @api.create_entity('Customer', customer_data)
      qb_id = response.dig('Customer', 'Id')
      raise "QB customer create returned no Id for contact ##{contact.id}" if qb_id.blank?

      customer_handler.save_quickbooks_id(contact, qb_id)

      { value: qb_id }
    else
      raise "Payment must have a contact to sync to QuickBooks"
    end
  end
  
  def get_deposit_account_ref(config)
    # Use account mapping: operating_cash
    # Fallback to Undeposited Funds or first Bank account
    begin
      get_account_from_mapping(
        :assets_liabilities,
        :operating_cash,
        "SELECT * FROM Account WHERE AccountType = 'Bank' MAXRESULTS 1"
      )
    rescue => e
      # If mapping fails, try Undeposited Funds as last resort
      Rails.logger.warn "[QB Sync] Could not use operating_cash mapping, falling back to Undeposited Funds: #{e.message}"
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
  
  # Build one Payment.Line per PaymentApplication so a payment split across
  # multiple invoices maps to QB's LinkedTxn model exactly. Unapplied credit
  # (payment.unapplied_amount > 0) rides as an additional line with no
  # LinkedTxn — QB accepts this and shows it as unapplied on the customer.
  def build_line_items(payment)
    lines = []

    applications = payment.payment_applications
                          .where(applicable_type: 'Invoice')
                          .includes(:applicable)

    applications.each do |app|
      invoice = app.applicable
      unless invoice&.quickbooks_id.present?
        raise "Payment ##{payment.id} applies to Invoice ##{invoice&.id || app.applicable_id} which is not yet synced to QuickBooks"
      end

      lines << {
        Amount: app.amount,
        LinkedTxn: [
          {
            TxnId:   invoice.quickbooks_id,
            TxnType: 'Invoice'
          }
        ]
      }
    end

    unapplied = payment.unapplied_amount
    if unapplied.present? && unapplied > 0
      lines << { Amount: unapplied }
    end

    # QB requires at least one Line — should already be true from applications
    # or unapplied, but be explicit.
    lines << { Amount: payment.amount } if lines.empty?

    lines
  end
  
  def find_contact_by_qb_id(customer_id)
    company.contacts.find_by(quickbooks_id: customer_id)
  end
end
