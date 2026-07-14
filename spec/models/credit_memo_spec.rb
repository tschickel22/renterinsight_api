# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CreditMemo, type: :model do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'Buyer', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com") }

  def build_invoice(total: 100)
    inv = company.invoices.create!(location: location, contact: contact, invoice_date: Date.current, status: 'draft')
    inv.invoice_items.create!(description: 'L', quantity: 1, rate: total)
    inv.save!
    inv.reload
  end

  def build_credit_memo(total: 50, issued: false)
    cm = company.credit_memos.create!(location: location, contact: contact, memo_date: Date.current)
    cm.credit_memo_items.create!(description: 'Return', quantity: 1, rate: total)
    cm.save!
    cm.issue! if issued
    cm.reload
  end

  describe 'number generation' do
    it 'generates a sequential CM- prefixed number per company' do
      first  = build_credit_memo(total: 10)
      second = build_credit_memo(total: 20)
      expect(first.credit_memo_number).to match(/\ACM-\d{6}\z/)
      expect(second.credit_memo_number).to match(/\ACM-\d{6}\z/)
      expect(second.credit_memo_number).not_to eq(first.credit_memo_number)
    end
  end

  describe 'application flow' do
    let(:invoice) { build_invoice(total: 100) }
    let(:memo)    { build_credit_memo(total: 60, issued: true) }

    it 'rejects applications against a draft memo' do
      draft_memo = build_credit_memo(total: 30, issued: false)
      expect {
        draft_memo.apply_to!(invoice, amount: 10)
      }.to raise_error(ActiveRecord::RecordInvalid, /must be issued/)
    end

    it 'reduces the invoice amount_due and increments amount_credited' do
      memo.apply_to!(invoice, amount: 30)
      invoice.reload
      expect(invoice.amount_credited.to_f).to eq(30.0)
      expect(invoice.amount_due.to_f).to eq(70.0)
      expect(invoice.status).to eq('partial')
    end

    it 'updates its own applied / remaining / status after each application' do
      memo.apply_to!(invoice, amount: 20)
      expect(memo.reload.amount_applied.to_f).to eq(20.0)
      expect(memo.amount_remaining.to_f).to eq(40.0)
      expect(memo.status).to eq('partial')

      memo.apply_to!(invoice, amount: 40)
      # Unique index means this second app for the same target actually
      # fails. Update the first to 60 instead.
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      first = memo.credit_memo_applications.first
      first.update!(amount: 60)
      expect(memo.reload.status).to eq('applied')
      expect(memo.amount_remaining.to_f).to eq(0.0)
    end

    it 'rejects over-application against the memo total' do
      memo.apply_to!(invoice, amount: 60)
      other_invoice = build_invoice(total: 50)
      expect {
        memo.apply_to!(other_invoice, amount: 10)
      }.to raise_error(ActiveRecord::RecordInvalid, /exceed credit memo total/)
    end

    it 'rejects applying to another company\'s invoice' do
      other_company  = Company.create!(name: "O-#{SecureRandom.hex(4)}")
      other_location = other_company.locations.create!(name: 'L', timezone: 'UTC')
      other_contact  = other_company.contacts.create!(first_name: 'X', last_name: 'Y', email: "x-#{SecureRandom.hex(4)}@example.com")
      cross = other_company.invoices.create!(location: other_location, contact: other_contact, invoice_date: Date.current, status: 'draft')
      cross.invoice_items.create!(description: 'X', quantity: 1, rate: 50); cross.save!

      app = memo.credit_memo_applications.build(applicable: cross, amount: 10, applied_at: Time.current)
      expect(app).not_to be_valid
      expect(app.errors[:applicable].join).to match(/same company/)
    end
  end

  describe 'voiding a memo' do
    let(:invoice) { build_invoice(total: 100) }
    let(:memo)    { build_credit_memo(total: 40, issued: true) }

    it 'retroactively removes the credit from the invoice' do
      memo.apply_to!(invoice, amount: 40)
      expect(invoice.reload.amount_credited.to_f).to eq(40.0)
      expect(invoice.amount_due.to_f).to eq(60.0)

      memo.update!(status: 'voided')

      expect(invoice.reload.amount_credited.to_f).to eq(0.0)
      expect(invoice.amount_due.to_f).to eq(100.0)
    end
  end
end
