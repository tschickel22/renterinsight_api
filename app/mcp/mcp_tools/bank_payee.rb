# frozen_string_literal: true

module McpTools
  # Suggests a GL account for an uncategorized bank transaction from how the
  # dealer categorized the same payee before.
  #
  # Bank descriptions carry noise that changes every time: dates, card
  # digits, check and trace numbers, store numbers, city and state. Two
  # payments to the same floor plan lender rarely share a description
  # character for character, so they are compared by a normalized payee key:
  #
  #   "POS DEBIT 09/14 HOME DEPOT #4521 DENVER CO"     -> "home depot denver"
  #   "ACH DEBIT 21ST MORTGAGE CORP PPD ID: 123456789" -> "21st mortgage corp"
  #   "CHECK 10482"                                    -> "check"
  #
  # When the full key has no history, the first two words are tried, so
  # "home depot aurora" still learns from "home depot denver".
  module BankPayee
    # Words banks add around the payee that say how, not who.
    NOISE_WORDS = %w[
      pos debit credit purchase payment pmt ach ppd ccd web tel ref id trace orig co name ind entry descr
      recurring card visa mastercard mc checkcard check chk dbt cr dr online transfer xfer
      withdrawal deposit wd dep authorized auth on from to the sq tst preauthorized ext
      des indn sec memo txn trn or mobile banking for of item details thank you
    ].freeze
    US_STATES = %w[
      al ak az ar ca co ct de fl ga hi id il in ia ks ky la me md ma mi mn ms mo mt ne nv nh nj nm ny nc nd
      oh ok or pa ri sc sd tn tx ut vt va wa wv wi wy dc
    ].freeze
    # Kept when nothing else is left, so "CHECK 10482" groups as checks.
    FALLBACK_WORDS = %w[check deposit transfer withdrawal payment fee interest].freeze

    module_function

    def key(description)
      text = description.to_s.downcase
      # ACH lines read "ORIG CO NAME:LOWES  ORIG ID:... DESC DATE:... TRACE#:...";
      # the originator name is the payee and the rest is noise.
      if (orig = text[/orig co name:\s*(.+?)(?:\s{2,}|\s+orig id|\s+desc date|\s+co entry|\z)/, 1])
        text = orig
      end
      text = text.gsub(%r{\b\d{1,2}/\d{1,2}(/\d{2,4})?\b}, ' ')     # dates
      text = text.gsub(/[#*]\s*\w*\d\w*/, ' ')                      # #4521, *1234, ref*abc123
      text = text.gsub(/\bx+\d+\b/, ' ')                           # xxxx1234
      text = text.gsub(/\b(?=\w*\d)(?!\d+(st|nd|rd|th)\b)\w{4,}\b/, ' ') # ids, trace numbers (keep 21st)
      text = text.gsub(/\b\d+\b/, ' ')                             # bare numbers
      text = text.gsub(/[^a-z0-9&' ]/, ' ')
      words = text.split
      kept = words.reject { |w| NOISE_WORDS.include?(w) || w.length < 2 }
      # A trailing "denver co" is where, not who.
      kept.pop if kept.size > 2 && US_STATES.include?(kept.last)
      kept = kept.first(4)
      return kept.join(' ') if kept.any?

      (words & FALLBACK_WORDS).first || words.first.to_s
    end

    # { payee key => { account_id => count } } from this company's history:
    # transactions already categorized by a person or a rule, or excluded
    # (counted under :excluded), in any bank account the person can see.
    def history(scope)
      rows = scope.where("(bank_transactions.status IN ('matched', 'reconciled') AND bank_transactions.category_account_id IS NOT NULL) " \
                         "OR bank_transactions.status = 'excluded'")
                  .order(transaction_date: :desc).limit(5_000)
                  .pluck(:description, Arel.sql("CASE WHEN bank_transactions.status = 'excluded' THEN NULL ELSE bank_transactions.category_account_id END"), :amount)
      rows.each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) do |(description, account_id, amount), memo|
        account_id ||= :excluded
        payee = key(description)
        out = amount.to_d.negative?
        memo[[payee, out]][account_id] += 1
        short = short_key(payee)
        memo[[:short, short, out]][account_id] += 1 if short != payee
      end
    end

    def short_key(payee)
      payee.split.first(2).join(' ')
    end

    # What kind of line this looks like: one short kind plus a note for the
    # person. A hint, never acted on by itself. Checked in order; the first
    # match wins. Every line gets a kind: when the wording says nothing (most
    # card and ACH payees), the direction still does, so looks_like is never
    # missing. It used to be left out whenever no word matched, which on a
    # feed of plain payee names was every line.
    KINDS = [
      [/\b(transfer|xfer)\b/, 'transfer',
       'Transfer between accounts: usually already booked on the other side, so exclude it or match it. ' \
       'Do not book it as income or expense.'],
      [/payment to .*card|card ending|epay|credit crd|mobile payment|autopay/, 'card payment',
       'Credit card payment: books against the card liability account, not an expense.'],
      [/floor ?plan|flooring|curtail/, 'floor plan',
       'Floor plan payment: principal reduces the floor plan liability; only interest and fees are expense.'],
      [/\A\s*(check|chk)\b/, 'check',
       'Check: the bank line does not say who it paid. Find the payee in the check register or the bill it paid.'],
      [/overdraft|service fee|wire fee|\bfee\b|service charge/, 'fee', 'Bank fee.'],
      [/\bdeposit\b|remote dep|mobile dep/, 'deposit',
       'Deposit: often a customer down payment or a cash receipt already recorded, so look for a match ' \
       'before booking it as income.']
    ].freeze
    DEPOSIT_KIND = KINDS.last.drop(1).freeze
    PAYMENT_KIND = ['payment', 'Money out, and nothing in the wording says more. Book it to what it paid for.'].freeze
    TRANSFER_NOTE = 'The account history or a rule points to is a bank or cash account, so booking it there records a transfer ' \
                    "between bank accounts, not income or expense. That is only right if the money moved between the " \
                    "dealer's own accounts, and then the other side is usually booked already: look for that entry " \
                    'and match it instead.'

    # [kind, note] for one line.
    def kind(description, amount)
      text = description.to_s.downcase
      found = KINDS.find { |pattern, _kind, _note| text.match?(pattern) }
      return found.drop(1) if found

      amount.to_d.negative? ? PAYMENT_KIND : DEPOSIT_KIND
    end

    # One or two earlier bookings are not a habit: below this many uses the
    # confidence is low however consistent they were.
    MIN_USES = 3

    def confidence(used, total, exact)
      level = if used < MIN_USES then 'low'
              elsif used == total then 'high'
              elsif used.to_f / total >= 0.75 then 'medium'
              else 'low'
              end
      # A similar payee (first two words) is a weaker signal than the same one.
      exact ? level : { 'high' => 'medium' }.fetch(level, 'low')
    end

    # What history and rules say about one transaction. Direction is part of the key:
    # money in from a payee is rarely booked like money out to them.
    # cash_account_ids: GL accounts that are bank or cash accounts. Booking a
    # line to one of those is a transfer, and is said so plainly.
    def suggest(txn, history, accounts_by_id, rules, cash_account_ids: Set.new)
      payee = key(txn.description)
      looks_like, note = kind(txn.description, txn.amount)
      out = { payee_key: payee, looks_like: looks_like, looks_like_note: note }

      rule = rules.find { |r| r.matches?(txn) }
      if rule
        out[:rule] = { name: rule.name, action: rule.action_type,
                       account: AccountingAccess.gl_account(accounts_by_id[rule.assign_account_id]) }.compact
        mark_transfer!(out, out[:rule]) if rule.assign_account_id && cash_account_ids.include?(rule.assign_account_id)
      end

      out_flow = txn.amount.to_d.negative?
      short = short_key(payee)
      # Every check reads "CHECK 1234": history says nothing about who it paid.
      return out if payee == 'check'

      exact = history.fetch([payee, out_flow], nil).presence
      counts = exact || history.fetch([:short, short, out_flow], nil).presence ||
               (history.fetch([short, out_flow], nil).presence if short != payee)
      if counts.present?
        total = counts.values.sum
        account_id, used = counts.max_by { |_id, n| n }
        basis = { times_used: used, out_of: total, confidence: confidence(used, total, exact),
                  based_on: exact ? 'same payee' : 'similar payee' }
        if account_id == :excluded
          out[:suggested_action] = basis.merge(action: 'exclude',
                                               why: 'Lines from this payee were excluded before (usually transfers or duplicates).')
        elsif (account = accounts_by_id[account_id])
          out[:suggested_account] = AccountingAccess.gl_account(account).merge(basis)
          mark_transfer!(out, out[:suggested_account]) if cash_account_ids.include?(account_id)
        end
        others = counts.except(account_id).sort_by { |_id, n| -n }.first(2).filter_map do |id, n|
          if id == :excluded then { action: 'exclude', times_used: n }
          elsif accounts_by_id[id] then AccountingAccess.gl_account(accounts_by_id[id]).merge(times_used: n)
          end
        end
        out[:also_used] = others if others.any?
      end
      out
    end

    def mark_transfer!(out, suggestion)
      out[:looks_like] = 'transfer'
      out[:looks_like_note] = TRANSFER_NOTE
      suggestion[:books_as] = 'transfer between bank accounts'
    end
  end
end
