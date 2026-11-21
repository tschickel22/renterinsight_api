# frozen_string_literal: true

require 'rails_helper'

# Floor plan interest posts once a day per home, only for homes still held,
# and a home going onto floor plan by any route takes the company defaults.
RSpec.describe 'Floor plan accrual and defaults' do
  let(:company) { create(:company, industry: 'manufactured_housing') }

  def home(**attrs)
    company.vehicles.create!({ listing_type: 'manufactured_home', make: 'Clayton', model: 'Tulip', year: 2026, status: 'available',
                               serial_number: "S-#{SecureRandom.hex(3)}", bedrooms: 3, bathrooms: 2 }.merge(attrs))
  end

  before do
    # The company's seeded chart carries 5300 and 2130; make sure they are there.
    company.chart_of_accounts.find_or_create_by!(account_number: '5300') { |a| a.assign_attributes(name: 'Floor Plan Interest', account_type: 'expense', normal_balance: 'debit') }
    company.chart_of_accounts.find_or_create_by!(account_number: '2130') { |a| a.assign_attributes(name: 'Floor Plan Interest Payable', account_type: 'liability', normal_balance: 'credit') }
    AccountingSettings.for_company(company).update!(floor_plan_tracking_enabled: true, default_floor_plan_rate: 8.25,
                                                    default_floor_plan_lender: 'Triad')
  end

  describe Accounting::FloorPlanService do
    let(:service) { described_class.new(company) }

    it 'charges a day once even when the job runs twice' do
      v = home(floor_plan_amount: 73_000, floor_plan_rate: 10, floor_plan_start_date: Date.current - 5)

      first = service.daily_interest_accrual
      second = service.daily_interest_accrual

      expect(first[:vehicles_processed]).to eq(1)
      expect(second[:vehicles_processed]).to eq(0)
      expect(company.journal_entries.where(source_entity: v).count).to eq(1)
      expect(v.reload.floor_plan_accrued_interest).to eq(20.0) # 73,000 x 10% / 365
    end

    it 'skips deleted homes and homes whose floor plan has not started' do
      home(floor_plan_amount: 73_000, floor_plan_rate: 10, floor_plan_start_date: Date.current - 5, is_deleted: true)
      home(floor_plan_amount: 73_000, floor_plan_rate: 10, floor_plan_start_date: Date.current + 2)

      expect(service.daily_interest_accrual[:vehicles_processed]).to eq(0)
      expect(company.journal_entries.count).to eq(0)
    end
  end

  describe 'a home going onto floor plan' do
    it 'takes the default rate, lender and a start date when created with an amount (a CSV import, the API)' do
      v = home(floor_plan_amount: 60_000, date_in_stock: Date.current - 4)

      expect(v).to have_attributes(floor_plan_rate: 8.25, floor_plan_lender: 'Triad', floor_plan_start_date: Date.current - 4)
    end

    it 'takes them when an amount is added later, and keeps what was typed' do
      v = home
      expect(v.floor_plan_rate).to be_nil

      v.update!(floor_plan_amount: 60_000, floor_plan_rate: 6.5)

      expect(v.reload).to have_attributes(floor_plan_rate: 6.5, floor_plan_lender: 'Triad', floor_plan_start_date: Date.current)
    end

    it 'leaves a home that is already on floor plan alone' do
      v = home(floor_plan_amount: 60_000, floor_plan_rate: 7, floor_plan_lender: 'Mine', floor_plan_start_date: Date.current - 9)
      v.update_columns(floor_plan_rate: nil)

      v.update!(floor_plan_amount: 61_000)

      expect(v.reload.floor_plan_rate).to be_nil
    end

    it 'does nothing for a home that is not on floor plan' do
      expect(home).to have_attributes(floor_plan_rate: nil, floor_plan_lender: nil, floor_plan_start_date: nil)
    end
  end

  describe 'interest from before tracking started' do
    let(:homes) { Accounting::FloorPlanHomes.new(company) }

    it 'posts the missed days once when the dealer says yes, and tonight does not post today again' do
      v = home
      result = homes.save(v, amount: 73_000, rate: 10, start_date: (Date.current - 9).iso8601, catch_up: true)

      expect(result.posted).to eq(200.0) # 73,000 x 10% / 365 x 10 days (start through today)
      expect(v.reload.floor_plan_accrued_interest).to eq(200.0)
      entry = company.journal_entries.find_by(source_entity: v)
      expect(entry.memo).to start_with('Floor plan interest before tracking started')
      expect(Accounting::FloorPlanService.new(company).daily_interest_accrual[:vehicles_processed]).to eq(0)

      again = homes.save(v, amount: 73_000, rate: 10, start_date: (Date.current - 9).iso8601, catch_up: true)
      expect(again.posted).to eq(0.0)
      expect(company.journal_entries.where(source_entity: v).count).to eq(1)
    end

    it 'posts nothing when the dealer says no' do
      v = home
      homes.save(v, amount: 73_000, rate: 10, start_date: (Date.current - 9).iso8601, catch_up: false)

      expect(company.journal_entries.count).to eq(0)
      expect(v.reload.floor_plan_accrued_interest).to eq(0)
    end

    it 'says so instead of posting when tracking is off' do
      AccountingSettings.for_company(company).update!(floor_plan_tracking_enabled: false)
      result = Accounting::FloorPlanHomes.new(company).save(home, amount: 73_000, rate: 10, start_date: (Date.current - 9).iso8601, catch_up: true)

      expect(result.posted).to eq(0.0)
      expect(result.note).to include('tracking is off')
      expect(company.journal_entries.count).to eq(0)
    end
  end

  describe 'the interest a deal shows' do
    it 'is what the books carry when tracking is on' do
      v = home(floor_plan_amount: 73_000, floor_plan_rate: 10, floor_plan_start_date: Date.current - 45)
      v.update_columns(floor_plan_accrued_interest: 412.33)

      expect(v.floor_plan_interest_to_date).to eq(412.33)
    end

    it 'is a daily estimate, not whole months, when tracking is off' do
      AccountingSettings.for_company(company).update!(floor_plan_tracking_enabled: false)
      v = home(floor_plan_amount: 73_000, floor_plan_rate: 10, floor_plan_start_date: Date.current - 45)

      expect(v.floor_plan_interest_to_date).to eq(900.0) # 73,000 x 10% / 365 x 45
    end
  end

end
