# frozen_string_literal: true

# QuickBooks CreditMemo Sync Handler
#
# Pushes issued (non-draft, non-voided) credit memos to QuickBooks as
# CreditMemo entities. Payloads mirror the invoice handler's shape — same
# CustomerRef resolution, same line-item + TxnTaxDetail (from
# invoice_item_taxes / tax_codes if configured), same SyncToken echo on
# update.
class QuickbooksCreditMemoSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'CreditMemo'
  end

  # Sync issued/partial/applied memos (push new/updated to QB), plus
  # voided memos that were previously synced (push the void so QB's copy
  # doesn't diverge from ours). Draft memos never sync until issued.
  def get_all_syncable_records
    scope = company.credit_memos.where(is_deleted: [false, nil])
    scope = scope.where(
      "(status IN ('issued','partial','applied')) OR (status = 'voided' AND quickbooks_id IS NOT NULL)"
    )
    scope = scope.where(location_id: location.id) if location.present?
    scope
  end

  def get_records_by_ids(ids)
    company.credit_memos.where(id: ids)
  end

  def get_records_by_quickbooks_ids(qb_ids)
    company.credit_memos.where(quickbooks_id: qb_ids)
  end

  # A voided memo that has already been pushed to QB needs a Void call,
  # not an update — QB treats "voided" as a discrete state transition.
  # Draft or already-unsynced memos have nothing to void.
  def should_void_in_qb?(memo)
    memo.status == 'voided' && memo.quickbooks_id.present?
  end

  def transform_to_quickbooks(memo, config)
    payload = {
      CustomerRef: get_customer_ref(memo),
      TxnDate:     memo.memo_date&.iso8601 || Date.today.iso8601,
      DocNumber:   memo.credit_memo_number,
      PrivateNote: [memo.reason, memo.notes].compact.reject(&:blank?).join(' — ').presence,
      Line:        build_line_items(memo)
    }

    tax_detail = build_txn_tax_detail(memo)
    payload[:TxnTaxDetail] = tax_detail if tax_detail

    if memo.quickbooks_id.present?
      payload[:Id] = memo.quickbooks_id
      payload[:SyncToken] = fetch_sync_token!('creditmemo', 'CreditMemo', memo.quickbooks_id)
    end

    payload.compact
  end

  def find_by_quickbooks_id(qb_id)
    company.credit_memos.find_by(quickbooks_id: qb_id)
  end

  def create_from_quickbooks(qb_memo, config)
    customer_id = qb_memo.dig('CustomerRef', 'value')
    contact = find_or_create_contact_from_qb(customer_id)

    resolved_location_id = location&.id ||
      (Current.location_filtered? ? Current.location_id : nil) ||
      company.locations.where(active: true, is_deleted: [false, nil]).order(:id).first&.id

    CreditMemo.transaction do
      memo = company.credit_memos.create!(
        location_id: resolved_location_id,
        contact_id:  contact&.id,
        quickbooks_id: qb_memo['Id'],
        credit_memo_number: qb_memo['DocNumber'] || "QB-CM-#{qb_memo['Id']}",
        memo_date:   qb_memo['TxnDate'] ? Date.parse(qb_memo['TxnDate']) : Date.today,
        status:      'issued',
        reason:      qb_memo['PrivateNote'],
        quickbooks_synced_at: Time.current
      )
      create_line_items_from_qb(memo, qb_memo)

      total_amt = qb_memo['TotalAmt'].to_f
      tax_amt   = qb_memo.dig('TxnTaxDetail', 'TotalTax').to_f
      subtotal  = total_amt - tax_amt
      remaining = qb_memo['RemainingCredit'].to_f
      applied   = total_amt - remaining

      memo.update_columns(
        subtotal:         subtotal,
        tax_amount:       tax_amt,
        total:            total_amt,
        amount_applied:   applied,
        amount_remaining: remaining,
        updated_at:       memo.updated_at
      )
      memo
    end
  end

  def update_from_quickbooks(memo, qb_memo, config)
    memo.credit_memo_items.destroy_all
    create_line_items_from_qb(memo, qb_memo)

    total_amt = qb_memo['TotalAmt'].to_f
    tax_amt   = qb_memo.dig('TxnTaxDetail', 'TotalTax').to_f
    subtotal  = total_amt - tax_amt
    remaining = qb_memo['RemainingCredit'].to_f
    applied   = total_amt - remaining

    memo.update_columns(
      credit_memo_number: qb_memo['DocNumber'] || memo.credit_memo_number,
      memo_date:  qb_memo['TxnDate'] ? Date.parse(qb_memo['TxnDate']) : memo.memo_date,
      subtotal:   subtotal,
      tax_amount: tax_amt,
      total:      total_amt,
      amount_applied:   applied,
      amount_remaining: remaining,
      reason:     qb_memo['PrivateNote'],
      quickbooks_synced_at: Time.current,
      updated_at: memo.updated_at
    )
  end

  private

  def get_customer_ref(memo)
    contact = memo.contact
    raise "CreditMemo ##{memo.id} has no contact — cannot sync to QuickBooks" unless contact.present?

    if contact.quickbooks_id.present?
      { value: contact.quickbooks_id }
    else
      customer_handler = QuickbooksCustomerSyncHandler.new(@entity, @api)
      customer_data = customer_handler.transform_to_quickbooks(contact, {})
      response = @api.create_entity('Customer', customer_data)
      qb_id = response.dig('Customer', 'Id')
      raise "QB Customer create returned no Id for contact ##{contact.id}" if qb_id.blank?

      customer_handler.save_quickbooks_id(contact, qb_id)
      { value: qb_id }
    end
  end

  def build_line_items(memo)
    memo.credit_memo_items.map.with_index do |item, idx|
      {
        LineNum:    idx + 1,
        DetailType: 'SalesItemLineDetail',
        Amount:     item.amount || (item.quantity * item.rate),
        Description: item.description,
        SalesItemLineDetail: {
          Qty:       item.quantity || 1,
          UnitPrice: item.rate || 0
        }.compact
      }
    end
  end

  # Emit a QB TxnTaxDetail block built from CreditMemoItemTax snapshots.
  # Same shape as the invoice handler's version — one TaxLine per unique
  # TaxCode, with TaxRateRef, TaxPercent, and NetAmountTaxable. Returns
  # nil when the memo has no snapshots so QB computes tax from Item
  # defaults (parity with the invoice legacy path).
  def build_txn_tax_detail(memo)
    snapshots = CreditMemoItemTax.includes(:tax_code)
                                 .joins(:credit_memo_item)
                                 .where(credit_memo_items: { credit_memo_id: memo.id })
    return nil if snapshots.none?

    per_code = snapshots.group_by(&:tax_code)
    tax_lines = per_code.map do |code, rows|
      next nil unless code
      {
        Amount: rows.sum(&:computed_amount).round(2),
        DetailType: 'TaxLineDetail',
        TaxLineDetail: {
          TaxRateRef: code.qbo_tax_code_id.present? ? { value: code.qbo_tax_code_id } : nil,
          PercentBased: true,
          TaxPercent: code.rate,
          NetAmountTaxable: rows.sum(&:taxable_base).round(2)
        }.compact
      }
    end.compact

    return nil if tax_lines.empty?

    {
      TotalTax: snapshots.sum(&:computed_amount).round(2),
      TaxLine: tax_lines
    }
  end

  def find_or_create_contact_from_qb(customer_id)
    contact = company.contacts.find_by(quickbooks_id: customer_id)
    return contact if contact

    qb_customer = @api.get_entity('Customer', customer_id)
    QuickbooksCustomerSyncHandler.new(@entity, @api)
                                 .create_from_quickbooks(qb_customer['Customer'], {})
  rescue => e
    Rails.logger.error "Failed to find/create contact from QB (for CreditMemo import): #{e.message}"
    nil
  end

  def create_line_items_from_qb(memo, qb_memo)
    (qb_memo['Line'] || []).each do |line|
      next unless line['DetailType'] == 'SalesItemLineDetail'
      detail = line['SalesItemLineDetail']
      memo.credit_memo_items.create!(
        description: line['Description'] || 'Line',
        quantity:    detail['Qty'] || 1,
        rate:        detail['UnitPrice'] || 0,
        amount:      line['Amount'] || 0
      )
    end
  end
end
