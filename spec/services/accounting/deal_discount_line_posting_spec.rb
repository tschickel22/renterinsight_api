# frozen_string_literal: true

require 'rails_helper'

# A negative line on a deal (a discount typed in Products or carried from a
# discounted home) used to be skipped at posting, so revenue, receivables and
# tax all stayed at the full price while the deal screen showed the lower one.
RSpec.describe Accounting::DealAccountingService, 'discount lines' do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "p#{SecureRandom.hex(2)}@example.com") }
  let(:accounts) { company.chart_of_accounts.where(is_header: [false, nil]) }
  let(:ar) { accounts.where('name ILIKE ?', '%receivable%').first }
  let(:revenue) { accounts.where(account_type: 'revenue').first }
  let(:settings) { AccountingSettings.for_company(company) }

  before { settings.update!(default_ar_account: ar, default_sales_revenue_account: revenue) }

  def deal_with(tax:, notes: 'category:fee')
    deal = company.deals.create!(name: 'Sale', contact_id: buyer.id, delivery_state: 'IN', selling_price: 100_000)
    deal.deal_products.create!(product_name: 'Home', product_sku: 'CUSTOM-h', unit_price: 100_000, quantity: 1, notes: 'category:home')
    deal.deal_products.create!(product_name: 'Manager Discount', product_sku: 'CUSTOM-d', unit_price: -10_000, quantity: 1, tax: tax, notes: notes)
    deal.reload
  end

  def net(lines, account)
    lines.select { |l| l[:chart_of_account_id] == account.id }.sum { |l| l[:debit_amount].to_d - l[:credit_amount].to_d }
  end

  it 'takes the discount off revenue and off what the buyer owes, in balance' do
    lines = described_class.new(deal_with(tax: 0)).closing_lines
    expect(net(lines, ar)).to eq(90_000)
    expect(net(lines, revenue)).to eq(-90_000)
    expect(lines.sum { |l| l[:debit_amount].to_d }).to eq(lines.sum { |l| l[:credit_amount].to_d })
  end

  it 'bills the discounted amount on the invoice' do
    expect(DealInvoiceService.new(deal_with(tax: 0)).send(:booked_receivable)).to eq(90_000)
  end

  context 'with sales tax' do
    before { settings.update!(sales_tax_enabled: true, tax_rates_by_state: { 'IN' => { 'state' => '7' } }) }

    def taxed_on(deal)
      described_class.new(deal).sales_tax_preview[:total]
    end

    it 'lowers the taxed price for a discount marked taxable' do
      expect(taxed_on(deal_with(tax: -700))).to eq((90_000 * 0.65 * 0.07).round(2))
    end

    def add_line(deal, name, price, tax:, notes: 'category:fee')
      deal.deal_products.create!(product_name: name, product_sku: "CUSTOM-#{SecureRandom.hex(2)}", unit_price: price, quantity: 1, tax: tax, notes: notes)
      deal.reload
    end

    it 'adds a taxable fee to the taxed price' do
      deal = add_line(deal_with(tax: 0, notes: 'category:fee, taxable:no'), 'Setup', 5_000, tax: 350)
      expect(taxed_on(deal)).to eq((105_000 * 0.65 * 0.07).round(2))
    end

    it 'leaves a fee marked not taxable out of the taxed price' do
      deal = add_line(deal_with(tax: 0, notes: 'category:fee, taxable:no'), 'Doc fee', 500, tax: 0, notes: 'category:fee, taxable:no')
      expect(taxed_on(deal)).to eq((100_000 * 0.65 * 0.07).round(2))
    end

    it 'nets taxable fees and taxable discounts' do
      deal = add_line(deal_with(tax: -700), 'Accessory', 4_000, tax: 280, notes: 'category:accessory')
      expect(taxed_on(deal)).to eq((94_000 * 0.65 * 0.07).round(2))
    end

    # No home on it, so not a home sale: Indiana's 65% does not apply.
    it 'taxes a deal with no selling price from its taxable lines' do
      deal = company.deals.create!(name: 'Lines only', contact_id: buyer.id, delivery_state: 'IN', selling_price: 0)
      deal.deal_products.create!(product_name: 'Setup', product_sku: 'CUSTOM-s', unit_price: 5_000, quantity: 1, tax: 350, notes: 'category:service')
      expect(taxed_on(deal.reload)).to eq((5_000 * 0.07).round(2))
    end

    it 'lists the untaxed discount and a home marked not taxable for the approver, not the doc fee' do
      deal = deal_with(tax: 0, notes: 'category:fee, taxable:no')
      add_line(deal, 'Doc fee', 500, tax: 0, notes: 'category:fee, taxable:no')
      deal.deal_products.find_by(product_name: 'Home').update!(notes: 'category:home, taxable:no')
      lines = described_class.new(deal.reload).sales_tax_preview[:untaxed_lines]
      expect(lines).to contain_exactly(
        { name: 'Home', amount: 100_000.0, kind: 'home' },
        { name: 'Manager Discount', amount: -10_000.0, kind: 'discount' }
      )
    end

    it 'does not list a taxed line' do
      expect(described_class.new(deal_with(tax: -700)).sales_tax_preview[:untaxed_lines]).to eq([])
    end

    # Taxable switched on after the deal posted: the tax difference posts, and the
    # invoice, which bills total_tax_amount, follows it.
    it 'moves the saved tax total when a correction changes the tax' do
      deal = deal_with(tax: 0, notes: 'category:fee, taxable:no')
      service = described_class.new(deal)
      before = service.posting_lines
      deal.update_columns(gl_posted: true, total_tax_amount: 4550, tax_posted: true)
      deal.deal_products.find_by(product_name: 'Manager Discount').update!(tax: -700, notes: 'category:fee')
      deal.reload
      je = described_class.new(deal).post_change_adjustment!(before: before, memo: 'Deal changed after approval')
      expect(je).to be_present
      expect(deal.total_tax_amount).to eq((90_000 * 0.65 * 0.07).round(2))
      expect(DealInvoiceService.new(deal).deal_total).to eq(90_000 + (90_000 * 0.65 * 0.07).round(2))
    end

    it 'leaves the saved tax total alone when a correction moves no tax' do
      deal = deal_with(tax: 0, notes: 'category:fee, taxable:no')
      before = described_class.new(deal).posting_lines
      deal.update_columns(gl_posted: true, total_tax_amount: 4550)
      deal.deal_products.find_by(product_name: 'Manager Discount').update!(unit_price: -5_000)
      described_class.new(deal.reload).post_change_adjustment!(before: before, memo: 'Deal changed after approval')
      expect(deal.total_tax_amount).to eq(4550)
    end

    it 'leaves the taxed price alone for a discount marked not taxable' do
      expect(taxed_on(deal_with(tax: 0, notes: 'category:fee, taxable:no'))).to eq((100_000 * 0.65 * 0.07).round(2))
    end
  end
end
