# frozen_string_literal: true

require 'rails_helper'

# Every non-home line used to post as F&I, falling through to 4110 Extended
# Warranty Revenue: delivery and set, skirting and a porch were booked as
# warranty sales. They are part of the sale; only F&I products are F&I.
RSpec.describe Accounting::DealAccountingService, 'line revenue accounts' do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "p#{SecureRandom.hex(2)}@example.com") }
  let(:accounts) { company.chart_of_accounts.where(is_header: [false, nil]) }
  let(:ar) { accounts.where('name ILIKE ?', '%receivable%').first }
  let(:revenue) { accounts.find_by(account_number: '4010') }
  let(:settings) { AccountingSettings.for_company(company) }

  before { settings.update!(default_ar_account: ar, default_sales_revenue_account: revenue) }

  def credited(lines, number)
    acct = company.chart_of_accounts.find_by!(account_number: number)
    lines.select { |l| l[:chart_of_account_id] == acct.id }.sum { |l| l[:credit_amount].to_d - l[:debit_amount].to_d }
  end

  it 'books delivery and set to delivery income, a doc fee to document fees, and only F&I products to F&I' do
    deal = company.deals.create!(name: 'Sale', contact_id: buyer.id, selling_price: 100_000)
    deal.deal_products.create!(product_name: 'Home', product_sku: 'CUSTOM-h', unit_price: 100_000, quantity: 1, notes: 'category:home')
    deal.deal_products.create!(product_name: 'Delivery and set', product_sku: 'CUSTOM-a', unit_price: 6500, quantity: 1, notes: 'category:service')
    deal.deal_products.create!(product_name: 'Vinyl skirting', product_sku: 'CUSTOM-b', unit_price: 2400, quantity: 1, notes: 'category:accessory')
    deal.deal_products.create!(product_name: 'Doc Fee', product_sku: 'CUSTOM-c', unit_price: 300, quantity: 1, notes: 'category:fee')
    deal.deal_products.create!(product_name: '5 year service contract', product_sku: 'CUSTOM-d', unit_price: 1200, quantity: 1, notes: 'category:product')

    lines = described_class.new(deal.reload).closing_lines
    expect(credited(lines, '4300')).to eq(8900)  # Delivery & Setup Income
    expect(credited(lines, '4520')).to eq(300)   # Document Fees
    expect(credited(lines, '4110')).to eq(1200)  # the F&I product only
    expect(lines.select { |l| l[:department] == 'fi' }.sum { |l| l[:credit_amount].to_d }).to eq(1200)
    expect(lines.sum { |l| l[:debit_amount].to_d }).to eq(lines.sum { |l| l[:credit_amount].to_d })
  end

  it 'relieves the inventory account set in Accounting Settings, the one receiving debits' do
    own = company.chart_of_accounts.create!(account_number: '1299', name: 'Homes on Lot', account_type: 'asset', normal_balance: 'debit')
    settings.update!(default_vehicle_inventory_account: own, default_cogs_account: accounts.find_by(account_number: '5010') || accounts.where(account_type: 'expense').first)
    deal = company.deals.create!(name: 'Sale', contact_id: buyer.id, selling_price: 100_000, home_cost: 70_000)
    lines = described_class.new(deal).closing_lines
    expect(lines.find { |l| l[:chart_of_account_id] == own.id }&.dig(:credit_amount)).to eq(70_000)
  end
end
