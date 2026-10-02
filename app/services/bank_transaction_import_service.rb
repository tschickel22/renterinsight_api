# frozen_string_literal: true

require 'digest'

class BankTransactionImportService
  def initialize(company)
    @company = company
  end

  # column_map examples:
  #   { date: 0, description: 1, amount: 2, reference: 3, date_format: '%m/%d/%Y' }
  #   { date: 'Date', description: 'Description', debit: 'Debit', credit: 'Credit' }
  def import(bank_account:, rows:, column_map:)
    imported = 0
    skipped = 0
    errors_list = []

    rows.each_with_index do |row, index|
      begin
        txn_date = parse_date(row, column_map)
        amount = parse_amount(row, column_map)
        description = extract_field(row, column_map[:description])&.strip
        reference = extract_field(row, column_map[:reference])&.strip

        next if txn_date.nil? || amount.nil? || amount.zero?

        fitid = Digest::SHA256.hexdigest(
          "#{txn_date}|#{amount}|#{description}|#{reference}"
        )[0..31]

        if bank_account.bank_transactions.exists?(fitid: fitid)
          skipped += 1
          next
        end

        bank_account.bank_transactions.create!(
          company: @company,
          transaction_date: txn_date,
          post_date: txn_date,
          description: description,
          amount: amount,
          reference_number: reference,
          fitid: fitid,
          status: 'unmatched',
          transaction_type: amount >= 0 ? 'credit' : 'debit'
        )
        imported += 1

      rescue => e
        errors_list << { row: index + 1, error: e.message }
      end
    end

    if imported > 0
      matcher = BankTransactionMatchingService.new(@company)
      matcher.auto_match_all(bank_account)
    end

    { imported: imported, skipped: skipped, errors: errors_list }
  end

  private

  def extract_field(row, key)
    return nil if key.nil?
    row[key] if key.is_a?(Integer) || key.is_a?(String)
  end

  def parse_date(row, column_map)
    raw = extract_field(row, column_map[:date])
    return nil if raw.blank?

    text = raw.to_s.strip
    format = column_map[:date_format] || '%m/%d/%Y'
    date = [format, '%m/%d/%Y', '%Y-%m-%d', '%m-%d-%Y', '%d/%m/%Y'].uniq.lazy.filter_map do |fmt|
      Date.strptime(text, fmt)
    rescue Date::Error
      nil
    end.first
    century_fix(date)
  end

  # %Y reads "5/5/25" as the year 25 instead of failing, and Heartland's
  # whole first import (286 lines, then every entry posted from them) landed
  # in the year 25. Bank exports with two-digit years mean this century.
  def century_fix(date)
    return date if date.nil? || date.year >= 100

    date >> (2000 * 12)
  end

  def parse_amount(row, column_map)
    if column_map[:amount]
      raw = extract_field(row, column_map[:amount])
      return nil if raw.blank?
      clean = raw.to_s.gsub(/[$,\s]/, '')
      BigDecimal(clean)
    elsif column_map[:debit] || column_map[:credit]
      debit_raw = extract_field(row, column_map[:debit])
      credit_raw = extract_field(row, column_map[:credit])

      debit = debit_raw.present? ? BigDecimal(debit_raw.to_s.gsub(/[$,\s]/, '')) : BigDecimal('0')
      credit = credit_raw.present? ? BigDecimal(credit_raw.to_s.gsub(/[$,\s]/, '')) : BigDecimal('0')

      credit - debit
    end
  rescue ArgumentError, TypeError
    nil
  end
end
