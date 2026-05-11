# frozen_string_literal: true

class BankReconciliationService
  def initialize(company)
    @company = company
  end

  def start(bank_account:, statement_date:, statement_ending_balance:)
    last_rec = bank_account.bank_reconciliations.completed.order(statement_date: :desc).first
    beginning_balance = last_rec&.statement_ending_balance || bank_account.opening_balance || BigDecimal('0')

    rec = @company.bank_reconciliations.build(
      bank_account: bank_account,
      statement_date: statement_date,
      statement_ending_balance: statement_ending_balance,
      beginning_balance: beginning_balance,
      status: 'in_progress'
    )

    unless rec.save
      return { error: rec.errors.full_messages.join(', ') }
    end

    populate_items(rec, bank_account, statement_date)
    rec.recalculate!
    rec
  end

  def toggle_item(rec_item)
    rec_item.toggle_cleared!
    rec_item.bank_reconciliation.reload
  end

  def clear_all(reconciliation)
    reconciliation.bank_reconciliation_items.update_all(cleared: true)
    reconciliation.recalculate!
  end

  def unclear_all(reconciliation)
    reconciliation.bank_reconciliation_items.update_all(cleared: false)
    reconciliation.recalculate!
  end

  def complete(reconciliation, user)
    reconciliation.complete!(user)
  end

  def delete(reconciliation)
    unless reconciliation.in_progress?
      return { error: 'Cannot delete a completed reconciliation' }
    end

    reconciliation.destroy
    { success: true }
  end

  # Undo the most recent completed reconciliation for its bank account.
  # Validates this IS the latest completed one — you can't undo older ones
  # because that would break the beginning-balance chain.
  def undo(reconciliation)
    unless reconciliation.status == 'completed'
      return { error: 'Only completed reconciliations can be undone' }
    end

    latest_completed = reconciliation.bank_account
      .bank_reconciliations
      .where(status: 'completed')
      .order(statement_date: :desc, id: :desc)
      .first

    if latest_completed.nil? || latest_completed.id != reconciliation.id
      return { error: 'Only the most recent completed reconciliation can be undone. Undo newer reconciliations first.' }
    end

    # Check no in-progress reconciliation exists for this account
    in_progress = reconciliation.bank_account
      .bank_reconciliations
      .where(status: 'in_progress')
      .exists?

    if in_progress
      return { error: 'Cannot undo while another reconciliation is in progress for this account. Complete or delete it first.' }
    end

    reconciliation.update!(
      status: 'in_progress',
      completed_at: nil,
      completed_by_id: nil
    )
    reconciliation.bank_reconciliation_items.update_all(cleared: false)
    reconciliation.recalculate!

    { success: true }
  end

  def add_adjustment(reconciliation, amount:, account_id:, memo:, user:)
    return { error: 'Reconciliation is already completed' } unless reconciliation.in_progress?

    bank_gl_account = reconciliation.bank_account.chart_of_account
    adjustment_account = @company.chart_of_accounts.find(account_id)

    posting_service = Accounting::ManualPostingService.new(@company)

    je = if amount > 0
           posting_service.post_simple!(
             debit_account: bank_gl_account,
             credit_account: adjustment_account,
             amount: amount.abs,
             memo: "Reconciliation adjustment: #{memo}",
             entry_date: reconciliation.statement_date,
             posted_by: user
           )
         else
           posting_service.post_simple!(
             debit_account: adjustment_account,
             credit_account: bank_gl_account,
             amount: amount.abs,
             memo: "Reconciliation adjustment: #{memo}",
             entry_date: reconciliation.statement_date,
             posted_by: user
           )
         end

    if je
      je.journal_entry_lines.where(chart_of_account_id: bank_gl_account.id).each do |line|
        reconciliation.bank_reconciliation_items.create!(
          journal_entry_line: line,
          amount: line.net_amount,
          cleared: true
        )
      end

      reconciliation.recalculate!
      { journal_entry: je }
    else
      { error: 'Failed to create adjustment entry' }
    end
  end

  private

  def populate_items(reconciliation, bank_account, statement_date)
    bank_gl_account_id = bank_account.chart_of_account_id
    return unless bank_gl_account_id

    cleared_line_ids = BankReconciliationItem
      .joins(:bank_reconciliation)
      .where(
        bank_reconciliations: {
          bank_account_id: bank_account.id,
          status: 'completed'
        },
        cleared: true
      )
      .select(:journal_entry_line_id)

    uncleared_lines = JournalEntryLine
      .joins(:journal_entry)
      .where(
        chart_of_account_id: bank_gl_account_id,
        journal_entries: { company_id: @company.id, is_void: false }
      )
      .where('journal_entries.entry_date <= ?', statement_date)
      .where.not(id: cleared_line_ids)
      .includes(journal_entry: :posted_by)

    uncleared_lines.find_each do |line|
      reconciliation.bank_reconciliation_items.create!(
        journal_entry_line: line,
        amount: line.net_amount,
        cleared: false
      )
    end
  end
end
