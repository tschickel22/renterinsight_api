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

    it 'leaves the taxed price alone for a discount marked not taxable' do
      expect(taxed_on(deal_with(tax: 0, notes: 'category:fee, taxable:no'))).to eq((100_000 * 0.65 * 0.07).round(2))
    end
  end
end
