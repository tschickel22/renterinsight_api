# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'TaxCode-driven invoice taxes', type: :model do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'Buyer', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com") }

  def build_invoice(with_line_amount: 100, taxable: true)
    inv = company.invoices.create!(
      location: location, contact: contact,
      invoice_date: Date.current, status: 'draft'
    )
    inv.invoice_items.create!(description: 'Line', quantity: 1, rate: with_line_amount, taxable: taxable)
    inv.save!
    inv.reload
  end

  describe 'validations' do
    it 'requires unique names per company (case-insensitive)' do
      company.tax_codes.create!(name: 'State', rate: 5, position: 1)
      dup = company.tax_codes.build(name: 'state', rate: 4, position: 2)
      expect(dup).not_to be_valid
      expect(dup.errors[:name].join).to match(/taken/i)
    end

    it 'rejects negative rates' do
      code = company.tax_codes.build(name: 'Neg', rate: -1, position: 1)
      expect(code).not_to be_valid
    end
  end

  describe 'non-compound taxes' do
    before { company.tax_codes.create!(name: 'State', rate: 5, is_compound: false, position: 1) }

    it 'taxes each line item on its own subtotal' do
      inv = build_invoice(with_line_amount: 100)
      expect(inv.tax_amount.to_f).to eq(5.0)
      expect(inv.total.to_f).to eq(105.0)
    end
  end

  describe 'compound taxes' do
    before do
      company.tax_codes.create!(name: 'State',   rate: 5, is_compound: false, position: 1)
      company.tax_codes.create!(name: 'Special', rate: 2, is_compound: true,  position: 2)
    end

    it 'stacks the compound code on top of the running total in position order' do
      inv = build_invoice(with_line_amount: 100)
      # State: 5% of 100 = 5. Compound: 2% of (100 + 5) = 2.10. Total 7.10.
      expect(inv.tax_amount.to_f).to eq(7.10)
      expect(inv.total.to_f).to eq(107.10)
    end

    it 'stores per-tax-code snapshots with the exact taxable base each used' do
      inv = build_invoice(with_line_amount: 100)
      snapshots = inv.invoice_items.first.invoice_item_taxes.includes(:tax_code)
      state = snapshots.find { |s| s.tax_code.name == 'State' }
      spec  = snapshots.find { |s| s.tax_code.name == 'Special' }
      expect(state.taxable_base.to_f).to eq(100.0)
      expect(state.computed_amount.to_f).to eq(5.0)
      expect(spec.taxable_base.to_f).to eq(105.0)
      expect(spec.computed_amount.to_f).to eq(2.10)
    end
  end

  describe 'tax exemptions' do
    before { company.tax_codes.create!(name: 'State', rate: 5, position: 1) }

    it 'zeros taxes when the contact is tax_exempt' do
      contact.update!(tax_exempt: true)
      inv = build_invoice(with_line_amount: 100)
      expect(inv.tax_amount.to_f).to eq(0.0)
      expect(inv.invoice_items.first.invoice_item_taxes).to be_empty
    end

    it 'zeros taxes for a specific line via skip_tax without touching other lines' do
      inv = company.invoices.create!(location: location, contact: contact, invoice_date: Date.current, status: 'draft')
      inv.invoice_items.create!(description: 'Taxed',   quantity: 1, rate: 100, taxable: true, skip_tax: false)
      inv.invoice_items.create!(description: 'Skipped', quantity: 1, rate: 100, taxable: true, skip_tax: true)
      inv.save!
      inv.reload
      expect(inv.tax_amount.to_f).to eq(5.0) # only the first line
    end
  end

  describe 'legacy fallback when no TaxCodes exist' do
    it 'uses invoice.tax_rate * subtotal like the pre-TaxCode behavior' do
      inv = company.invoices.create!(
        location: location, contact: contact,
        invoice_date: Date.current, status: 'draft',
        tax_rate: 7.5
      )
      inv.invoice_items.create!(description: 'Legacy', quantity: 1, rate: 200, taxable: true)
      inv.save!
      inv.reload
      # No active TaxCodes → after_save finalize is skipped, calculate_totals
      # legacy branch fires (item.tax_amount falls back to item/invoice tax_rate).
      expect(inv.tax_amount.to_f).to eq(15.0)
      expect(inv.total.to_f).to eq(215.0)
    end
  end
end
