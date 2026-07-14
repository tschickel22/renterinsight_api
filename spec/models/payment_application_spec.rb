# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PaymentApplication, type: :model do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'Payer', last_name: 'One', email: "p-#{SecureRandom.hex(4)}@example.com") }

  def build_invoice(total: 100, company: nil, contact: nil, location: nil)
    company  ||= self.company
    location ||= self.location
    contact  ||= self.contact
    inv = company.invoices.create!(
      location: location,
      contact: contact,
      invoice_date: Date.current,
      status: 'draft'
    )
    inv.invoice_items.create!(description: 'Line', quantity: 1, rate: total)
    inv.save!
    inv.reload
  end

  def build_payment(amount:, status: 'completed', company: nil, contact: nil, location: nil)
    company  ||= self.company
    location ||= self.location
    contact  ||= self.contact
    company.payments.create!(
      amount: amount,
      payment_type: 'one_time',
      status: status,
      payer: contact,
      payment_date: Date.current,
      gateway_name: 'manual',
      location: location
    )
  end

  describe 'validations' do
    let(:invoice) { build_invoice(total: 100) }
    let(:payment) { build_payment(amount: 50) }

    it 'requires a positive amount' do
      app = payment.payment_applications.build(company: company, applicable: invoice, amount: 0, applied_at: Time.current)
      expect(app).not_to be_valid
      expect(app.errors[:amount]).to include(a_string_matching(/greater than 0/))
    end

    it 'defaults applied_at and company from the payment on create' do
      app = payment.payment_applications.create!(applicable: invoice, amount: 25)
      expect(app.applied_at).to be_present
      expect(app.company_id).to eq(company.id)
    end

    it 'rejects applications that would exceed the payment amount' do
      payment.apply_to!(invoice, amount: 30)
      dup = payment.payment_applications.build(applicable: invoice, amount: 25, applied_at: Time.current)
      # Second application to same invoice trips the unique index, but the
      # amount validator fires first with a message about the exceeded total.
      expect(dup).not_to be_valid
      expect(dup.errors[:amount].join).to match(/exceed payment amount/)
    end

    it 'rejects an applicable that belongs to a different company' do
      other_company  = Company.create!(name: "O-#{SecureRandom.hex(4)}")
      other_location = other_company.locations.create!(name: 'L', timezone: 'UTC')
      other_contact  = other_company.contacts.create!(first_name: 'X', last_name: 'Y', email: "x-#{SecureRandom.hex(4)}@example.com")
      cross = build_invoice(total: 50, company: other_company, location: other_location, contact: other_contact)

      # Apply first so the amount validator has capacity; the tenant check is what we're proving.
      app = payment.payment_applications.build(applicable: cross, amount: 10, applied_at: Time.current)
      expect(app).not_to be_valid
      expect(app.errors[:applicable].join).to match(/same company/)
    end
  end

  describe 'invoice paid-state recomputation' do
    let(:invoice) { build_invoice(total: 100) }

    it 'moves an invoice from draft to partial then paid as applications land' do
      payment_one = build_payment(amount: 40)
      payment_one.apply_to!(invoice, amount: 40)
      expect(invoice.reload.status).to eq('partial')
      expect(invoice.amount_paid.to_f).to eq(40.0)

      payment_two = build_payment(amount: 60)
      payment_two.apply_to!(invoice, amount: 60)
      expect(invoice.reload.status).to eq('paid')
      expect(invoice.amount_paid.to_f).to eq(100.0)
      expect(invoice.amount_due.to_f).to eq(0.0)
    end

    it 'does not count applications from non-completed payments' do
      pending_payment = build_payment(amount: 25, status: 'pending')
      pending_payment.apply_to!(invoice, amount: 25)
      expect(invoice.reload.amount_paid.to_f).to eq(0.0)
      expect(invoice.status).to eq('draft')
    end

    it 'updates the invoice when a pending payment retroactively completes' do
      payment = build_payment(amount: 100, status: 'pending')
      payment.apply_to!(invoice, amount: 100)
      expect(invoice.reload.amount_paid.to_f).to eq(0.0)

      payment.update!(status: 'completed')
      expect(invoice.reload.status).to eq('paid')
      expect(invoice.amount_paid.to_f).to eq(100.0)
    end
  end

  describe 'unapplied credit on a payment' do
    let(:invoice) { build_invoice(total: 100) }

    it 'reports applied_amount and unapplied_amount' do
      payment = build_payment(amount: 150)
      payment.apply_to!(invoice, amount: 20)
      expect(payment.applied_amount.to_f).to eq(20.0)
      expect(payment.unapplied_amount.to_f).to eq(130.0)
      expect(payment.fully_applied?).to be(false)
    end
  end
end
