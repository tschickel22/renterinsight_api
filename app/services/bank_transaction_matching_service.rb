# frozen_string_literal: true

require 'set'

class BankTransactionMatchingService
  def initialize(company)
    @company = company
  end

  def auto_match(bank_transaction)
    return if bank_transaction.matched?

    rule_result = apply_rules(bank_transaction)
    if rule_result
      handle_rule_match(bank_transaction, rule_result)
      return
    end

    if bank_transaction.withdrawal? && bank_transaction.reference_number.present?
      check_match = find_by_check_number(bank_transaction)
      if check_match
        bank_transaction.match_to_journal_entry!(check_match, source: 'auto')
        return
      end
    end

    exact_matches = find_exact_matches(bank_transaction)
    if exact_matches.count == 1
      bank_transaction.match_to_journal_entry!(exact_matches.first.journal_entry, source: 'auto')
      return
    end

    fuzzy_matches = find_fuzzy_matches(bank_transaction, days_range: 3)
    if fuzzy_matches.count == 1
      bank_transaction.match_to_journal_entry!(fuzzy_matches.first.journal_entry, source: 'auto')
    end
  end

  def auto_match_all(bank_account)
    matched_count = 0
    bank_account.bank_transactions.unmatched.find_each do |txn|
      auto_match(txn)
      matched_count += 1 if txn.reload.matched?
    end
    matched_count
  end

  def suggest_matches(bank_transaction, limit: 5)
    return [] if bank_transaction.matched?

    bank_gl_account_id = bank_transaction.bank_account.chart_of_account_id
    return [] unless bank_gl_account_id

    je_lines = JournalEntryLine
      .joins(:journal_entry)
      .where(
        chart_of_account_id: bank_gl_account_id,
        journal_entries: { company_id: @company.id, is_void: false }
      )
      .where(
        journal_entries: {
          entry_date: (bank_transaction.transaction_date - 14.days)..(bank_transaction.transaction_date + 14.days)
        }
      )
      .where.not(
        journal_entry_id: BankTransaction
          .where(bank_account_id: bank_transaction.bank_account_id)
          .where.not(matched_journal_entry_id: nil)
          .select(:matched_journal_entry_id)
      )
      .where.not(id: BankReconciliationItem.select(:journal_entry_line_id))

    candidates = []
    je_lines.each do |line|
      score = calculate_match_score(bank_transaction, line)
      next if score < 0.2

      candidates << {
        journal_entry_id: line.journal_entry_id,
        journal_entry_line_id: line.id,
        entry_number: line.journal_entry.entry_number,
        entry_date: line.journal_entry.entry_date,
        memo: line.memo.presence || line.journal_entry.memo,
        debit: line.debit_amount.zero? ? nil : line.debit_amount,
        credit: line.credit_amount.zero? ? nil : line.credit_amount,
        line_amount: line.net_amount,
        score: score.round(3),
        source_type: line.journal_entry.source_type
      }
    end

    candidates.sort_by { |c| -c[:score] }.first(limit)
  end

  private

  def apply_rules(bank_transaction)
    rules = @company.bank_rules
      .active
      .for_account(bank_transaction.bank_account_id)
      .by_priority

    rules.find { |rule| rule.matches?(bank_transaction) }
  end

  def handle_rule_match(bank_transaction, rule)
    rule.record_match!

    bank_transaction.update!(
      category_account_id: rule.assign_account_id,
      contact_id: rule.assign_contact_id,
      memo: rule.assign_memo.presence || bank_transaction.memo,
      rule_id: rule.id,
      matched_at: Time.current,
      matched_by: 'rule'
    )

    if rule.auto_confirm
      bank_transaction.create_journal_entry_from_categorization!
      bank_transaction.update!(status: 'matched')
    else
      bank_transaction.update!(status: 'matched')
    end
  end

  def find_by_check_number(bank_transaction)
    JournalEntry
      .where(company_id: @company.id, is_void: false)
      .where("memo ILIKE ?", "%check%#{bank_transaction.reference_number}%")
      .first
  end

  def find_exact_matches(bank_transaction)
    bank_gl_account_id = bank_transaction.bank_account.chart_of_account_id
    return JournalEntryLine.none unless bank_gl_account_id

    JournalEntryLine
      .joins(:journal_entry)
      .where(
        chart_of_account_id: bank_gl_account_id,
        journal_entries: { company_id: @company.id, is_void: false, entry_date: bank_transaction.transaction_date }
      )
      .where(matching_amount_condition(bank_transaction))
      .where.not(journal_entry_id: matched_je_ids(bank_transaction.bank_account_id))
  end

  def find_fuzzy_matches(bank_transaction, days_range: 3)
    bank_gl_account_id = bank_transaction.bank_account.chart_of_account_id
    return JournalEntryLine.none unless bank_gl_account_id

    date_range = (bank_transaction.transaction_date - days_range.days)..(bank_transaction.transaction_date + days_range.days)

    JournalEntryLine
      .joins(:journal_entry)
      .where(
        chart_of_account_id: bank_gl_account_id,
        journal_entries: { company_id: @company.id, is_void: false, entry_date: date_range }
      )
      .where(matching_amount_condition(bank_transaction))
      .where.not(journal_entry_id: matched_je_ids(bank_transaction.bank_account_id))
  end

  def matching_amount_condition(bank_transaction)
    abs_amount = bank_transaction.amount.abs
    if bank_transaction.deposit?
      ['credit_amount = ?', abs_amount]
    else
      ['debit_amount = ?', abs_amount]
    end
  end

  def matched_je_ids(bank_account_id)
    BankTransaction
      .where(bank_account_id: bank_account_id)
      .where.not(matched_journal_entry_id: nil)
      .select(:matched_journal_entry_id)
  end

  def calculate_match_score(bank_transaction, je_line)
    score = 0.0

    txn_amount = bank_transaction.amount
    compared = bank_transaction.deposit? ? je_line.credit_amount : je_line.debit_amount

    if compared == txn_amount.abs
      score += 0.5
    elsif (compared - txn_amount.abs).abs < 1.00
      score += 0.2
    else
      return 0.0
    end

    day_diff = (bank_transaction.transaction_date - je_line.journal_entry.entry_date).to_i.abs
    score += case day_diff
             when 0 then 0.3
             when 1..3 then 0.2
             when 4..7 then 0.1
             else 0.0
             end

    if bank_transaction.description.present? && je_line.memo.present?
      txn_words = bank_transaction.description.downcase.split(/\s+/).to_set
      memo_words = je_line.memo.downcase.split(/\s+/).to_set
      overlap = (txn_words & memo_words).size
      total = [txn_words.size, memo_words.size].max
      similarity = total > 0 ? overlap.to_f / total : 0
      score += similarity * 0.2
    end

    score
  end
end
