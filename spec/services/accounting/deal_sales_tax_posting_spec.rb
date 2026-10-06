# frozen_string_literal: true

require 'rails_helper'

# B28: GL posting taxed a manufactured home on its full price. It now posts
# what the deal sheet quotes, by the taxing state's rules (Tax::DealTax).
RSpec.describe Accounting::DealAccountingService, '#post_sales_tax_entries!' do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "p#{SecureRandom.hex(2)}@example.com") }

  before do
    ar = company.chart_of_accounts.where(is_header: [false, nil]).where('name ILIKE ?', '%receivable%').first
    AccountingSettings.for_company(company).update!(sales_tax_enabled: true, default_ar_account: ar)
  end

  def post_for(state)
    deal = company.deals.create!(name: 'Sale', contact_id: buyer.id, delivery_state: state, selling_price: 83_688.70)
    [deal, described_class.new(deal).post_sales_tax_entries!]
  end

  it 'posts Indiana tax on 65% of the price' do
    deal, result = post_for('IN')
    expect(result[:total_tax]).to eq(3807.84)
    expect(deal.reload).to have_attributes(total_tax_amount: 3807.84, tax_posted: true)
  end

  it 'posts nothing where the dealer does not collect' do
    deal, result = post_for('MI')
    expect(result[:skipped]).to eq('not_collected_in_MI')
    expect(deal.reload.tax_posted).to be(false)
  end
end
