# frozen_string_literal: true

require 'rails_helper'

# Account Mappings (Accounting Settings) are saved per Location. Deal closing
# and invoice posting resolve through Accounting::AccountLinkResolver, which
# used to skip Location links, so every saved mapping was ignored and sales
# posted to the default accounts.
RSpec.describe Accounting::AccountLinkResolver do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:other_location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'Pat', last_name: 'Buyer', email: "b-#{SecureRandom.hex(4)}@example.com") }
  let(:settings) { AccountingSettings.for_company(company) }
  let(:postable) { company.chart_of_accounts.active.postable }
  let(:revenues) { postable.where(account_type: 'revenue').order(:account_number).to_a }
  let(:default_revenue) { revenues[0] }
  let(:mapped_revenue)  { revenues[1] }
  let(:other_revenue)   { revenues[2] }
  let(:ar) { postable.where(account_type: 'asset').where('name ILIKE ?', '%receivable%').order(:account_number).first }

  def map!(linkable, account, purpose: 'revenue', priority: 0, active: true)
    company.account_links.create!(linkable: linkable, chart_of_account: account, link_purpose: purpose,
                                  priority: priority, is_active: active)
  end

  before do
    skip 'seed chart has fewer than three revenue accounts' if revenues.size < 3
    skip 'seed chart has no receivable account' unless ar
    settings.update!(default_ar_account: ar, default_sales_revenue_account: default_revenue)
  end

  describe '.resolve' do
    let(:deal) { company.deals.create!(name: 'Sale', contact_id: contact.id, location_id: location.id) }

    it 'uses the Location mapping when nothing more specific exists' do
      map!(location, mapped_revenue)
      expect(described_class.resolve(company: company, entity: deal, purpose: 'revenue', location_id: location.id))
        .to eq(mapped_revenue)
    end

    it 'ignores another location, another purpose and inactive mappings' do
      map!(other_location, other_revenue)
      map!(location, other_revenue, purpose: 'cogs')
      map!(location, other_revenue, active: false)
      expect(described_class.resolve(company: company, entity: deal, purpose: 'revenue', location_id: location.id))
        .to be_nil
    end

    it 'lets a mapping on the exact record beat the location' do
      map!(location, mapped_revenue)
      map!(deal, other_revenue)
      expect(described_class.resolve(company: company, entity: deal, purpose: 'revenue', location_id: location.id))
        .to eq(other_revenue)
    end

    it 'lets the higher priority win between two mappings on the same location' do
      map!(location, other_revenue, priority: 0)
      map!(location, mapped_revenue, priority: 10)
      expect(described_class.resolve(company: company, entity: deal, purpose: 'revenue', location_id: location.id))
        .to eq(mapped_revenue)
    end

    it 'does not look at locations unless the caller names one' do
      map!(location, mapped_revenue)
      expect(described_class.resolve(company: company, entity: deal, purpose: 'revenue')).to be_nil
    end

    it 'never uses another company\'s mapping' do
      other = Company.create!(name: "O-#{SecureRandom.hex(4)}")
      other.account_links.create!(linkable: location, chart_of_account: mapped_revenue, link_purpose: 'revenue')
      expect(described_class.resolve(company: company, entity: deal, purpose: 'revenue', location_id: location.id))
        .to be_nil
    end
  end

  describe 'deal closing' do
    def revenue_credit(deal)
      Accounting::DealAccountingService.new(deal).closing_lines
                                       .find { |l| l[:credit_amount].to_d.positive? && l[:memo].to_s.start_with?('Deal revenue') }
    end

    it 'credits the sale to the location\'s mapped revenue account' do
      map!(location, mapped_revenue)
      deal = company.deals.create!(name: 'Sale', contact_id: contact.id, location_id: location.id, selling_price: 50_000)
      line = revenue_credit(deal.reload)
      expect(line[:chart_of_account_id]).to eq(mapped_revenue.id)
      expect(line[:location_id]).to eq(location.id)
    end

    it 'keeps the default revenue account at a location with no mapping' do
      map!(other_location, mapped_revenue)
      deal = company.deals.create!(name: 'Sale', contact_id: contact.id, location_id: location.id, selling_price: 50_000)
      expect(revenue_credit(deal.reload)[:chart_of_account_id]).to eq(default_revenue.id)
    end

    it 'debits COGS to the location\'s mapped COGS account' do
      cogs = postable.where(account_type: %w[expense cost_of_goods_sold cogs]).order(:account_number).to_a
      skip 'seed chart lacks inventory 1210 or two COGS accounts' unless company.chart_of_accounts.exists?(account_number: '1210') && cogs.size >= 2
      settings.update!(default_cogs_account: cogs[0])
      map!(location, cogs[1], purpose: 'cogs')
      deal = company.deals.create!(name: 'Sale', contact_id: contact.id, location_id: location.id,
                                   selling_price: 50_000, home_cost: 30_000)
      line = Accounting::DealAccountingService.new(deal.reload).closing_lines
                                              .find { |l| l[:memo].to_s.start_with?('COGS') }
      expect(line[:chart_of_account_id]).to eq(cogs[1].id)
    end
  end

  describe 'invoice posting' do
    def post_invoice(at)
      inv = company.invoices.create!(location: at, contact: contact, invoice_date: Date.current, status: 'draft')
      inv.invoice_items.create!(description: 'Service', quantity: 1, rate: 400)
      inv.save!
      inv.update!(status: 'sent')
      Accounting::InvoicePostingService.new(inv.reload).post!
    end

    def credited_accounts(je)
      je.journal_entry_lines.select { |l| l.credit_amount.to_d.positive? }.map(&:chart_of_account_id)
    end

    it 'credits revenue to the invoice location\'s mapped account' do
      map!(location, mapped_revenue)
      je = post_invoice(location)
      expect(je).to be_present
      expect(credited_accounts(je)).to include(mapped_revenue.id)
      expect(credited_accounts(je)).not_to include(default_revenue.id)
    end

    it 'keeps the default revenue account at a location with no mapping' do
      map!(other_location, mapped_revenue)
      je = post_invoice(location)
      expect(credited_accounts(je)).to include(default_revenue.id)
      expect(credited_accounts(je)).not_to include(mapped_revenue.id)
    end
  end
end
