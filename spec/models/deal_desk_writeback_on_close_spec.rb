# frozen_string_literal: true

require 'rails_helper'

# Enhancement 6: configurable Deal Desk write-back timing.
#
#   on_close (default) — the selected scenario is written back to the deal automatically
#                        inside the close save (before the GL post reads the figures).
#   on_apply           — write-back stays manual (the apply endpoint only).
#
# The on_close hook runs as a Deal#before_save and writes via ASSIGNMENT ONLY, so it folds
# into the in-flight UPDATE with no nested save (the re-entrancy fix). Commission gating
# (GL-approval) is untouched.
RSpec.describe 'Deal Desk configurable write-back timing', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@ex.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:unit) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, dealer_cost: 50_000,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end
  let(:deal) { company.deals.create!(name: 'Test Deal', account: account, vehicle: unit, location_id: location.id) }

  # A selected scenario whose economics DIFFER from the deal's auto-synced selling_price
  # (snapshot 65_000 vs vehicle 70_000) so any write-back is observable.
  def selected_scenario(attrs = {})
    company.deal_desk_scenarios.create!({
      deal: deal, vehicle: unit, location: location, status: 'selected',
      tax_mode: 'full_price', tax_rate: 0.05, term_months: 180, apr: 8.0,
      unit_price_snapshot: 65_000, unit_cost_snapshot: 50_000,
      cash_down: 5_000, amount_financed: 60_000, fees: { 'doc' => 599 }
    }.merge(attrs))
  end

  def set_mode(mode)
    Setting.set('Company', company.id, 'deal_desk_writeback_mode', mode)
  end

  # --- (e) Setting reader -----------------------------------------------------
  describe 'Company#deal_desk_writeback_mode' do
    it 'defaults to on_close when unset' do
      expect(company.deal_desk_writeback_mode).to eq('on_close')
    end

    it 'returns a valid stored value' do
      set_mode('on_apply')
      expect(company.deal_desk_writeback_mode).to eq('on_apply')
    end

    it 'falls back to on_close for an unrecognized stored value' do
      set_mode('bogus')
      expect(company.deal_desk_writeback_mode).to eq('on_close')
    end
  end

  # --- Shared write-back method (extraction) ----------------------------------
  describe 'DealDeskScenario#write_back_to_deal!' do
    it 'persists via deal.update when assign_only is false (the controller #apply path)' do
      s = selected_scenario
      deal.reload
      s.write_back_to_deal!(deal)
      expect(deal.reload.down_payment.to_f).to eq(5_000.0)
      expect(deal.selling_price.to_f).to eq(65_000.0)
    end

    it 'only ASSIGNS (no save) when assign_only is true' do
      s = selected_scenario
      deal.reload
      s.write_back_to_deal!(deal, assign_only: true)
      expect(deal.down_payment.to_f).to eq(5_000.0)   # in-memory
      expect(deal.has_changes_to_save?).to be(true)   # NOT persisted
      expect(deal.reload.down_payment.to_f).to eq(0.0) # DB untouched
    end

    it 'writes the snapshot cost to BOTH unit_cost and home_cost' do
      s = selected_scenario(unit_cost_snapshot: 52_000)
      deal.reload
      s.write_back_to_deal!(deal)
      deal.reload
      expect(deal.unit_cost.to_f).to eq(52_000.0)
      expect(deal.home_cost.to_f).to eq(52_000.0) # canonical accounting cost (GL reads this)
    end
  end

  # --- (a) on_close + selected: write-back AND GL reflects applied figures -----
  describe 'on_close mode with a selected scenario' do
    it 'writes the scenario back at close and the GL post reflects the applied figures' do
      selected_scenario
      ar  = company.chart_of_accounts.create!(account_number: '1200', name: 'Accounts Receivable',
                                              account_type: 'asset', normal_balance: 'debit')
      rev = company.chart_of_accounts.create!(account_number: '4000', name: 'Sales Revenue',
                                              account_type: 'revenue', normal_balance: 'credit')
      AccountingSettings.for_company(company)
                        .update!(default_ar_account: ar, default_sales_revenue_account: rev,
                                 auto_post_deals: false)

      expect(deal.reload.down_payment.to_f).to eq(0.0) # pre-close

      deal.update!(stage: 'closed_won')

      deal.reload
      expect(deal.selling_price.to_f).to eq(65_000.0)  # applied from scenario (was 70_000)
      expect(deal.down_payment.to_f).to eq(5_000.0)

      result = Accounting::DealAccountingService.new(deal).post_closing_entries!(user: user)
      expect(result[:success]).to be(true)

      je = company.journal_entries.find(deal.reload.gl_journal_entry_id)
      rev_line = je.journal_entry_lines.find { |l| l.chart_of_account_id == rev.id }
      expect(rev_line.credit_amount.to_f).to eq(65_000.0) # GL posts the DESKED figure
    end

    it 'uses the assignment path (no nested save / re-entrancy)' do
      selected_scenario
      expect_any_instance_of(DealDeskScenario)
        .to receive(:write_back_to_deal!).with(kind_of(Deal), assign_only: true).and_call_original
      expect { deal.update!(stage: 'closed_won') }.not_to raise_error # no SystemStackError
      expect(deal.reload.down_payment.to_f).to eq(5_000.0)
    end
  end

  # --- (b) on_close + no selected scenario ------------------------------------
  describe 'on_close mode with no selected scenario' do
    it 'closes normally without write-back and without raising' do
      company.deal_desk_scenarios.create!(deal: deal, vehicle: unit, status: 'active',
                                          tax_mode: 'full_price', cash_down: 5_000,
                                          unit_price_snapshot: 65_000)
      expect { deal.update!(stage: 'closed_won') }.not_to raise_error
      deal.reload
      expect(deal.stage).to eq('closed_won')
      expect(deal.down_payment.to_f).to eq(0.0) # nothing written back
    end
  end

  # --- (c) on_apply mode ------------------------------------------------------
  describe 'on_apply mode' do
    it 'does NOT auto-write at close; manual write-back still works' do
      set_mode('on_apply')
      s = selected_scenario

      deal.update!(stage: 'closed_won')
      deal.reload
      expect(deal.stage).to eq('closed_won')
      expect(deal.down_payment.to_f).to eq(0.0) # close did NOT write back

      s.write_back_to_deal!(deal.reload) # manual apply path
      expect(deal.reload.down_payment.to_f).to eq(5_000.0)
    end
  end

  # --- (d) commission gate unchanged ------------------------------------------
  describe 'commission gating' do
    it 'is untouched: the on_close write-back does not GL-post, so commission stays blocked' do
      selected_scenario
      deal.update!(stage: 'closed_won')
      deal.reload
      # write-back applied economics...
      expect(deal.down_payment.to_f).to eq(5_000.0)
      # ...but the deal is NOT GL-posted, so the commission approval gate still holds.
      expect(deal.gl_posted?).to be_falsey
    end
  end

  # --- (f) divergence guard ---------------------------------------------------
  describe 'divergence guard (deal hand-edited after selecting)' do
    it 'WARNs and still applies the scenario (source of truth at close)' do
      selected_scenario
      deal.update!(selling_price: 71_234) # hand-edited after selecting

      expect(Rails.logger).to receive(:warn).with(/diverges from selected scenario/).and_call_original

      deal.update!(stage: 'closed_won')
      expect(deal.reload.selling_price.to_f).to eq(65_000.0) # scenario wins
    end
  end

  # --- (g) unit-swap at close: cost follows the unit --------------------------
  describe 'unit-swap at close (cost follows the unit)' do
    it 'writes unit_cost AND home_cost from the snapshot; GL COGS reflects the swapped unit' do
      unit2 = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2025,
                                       make: 'Clayton', model: 'Edge', serial_number: "SN-#{SecureRandom.hex(4)}",
                                       bedrooms: 4, bathrooms: 2.0, sale_price: 80_000, dealer_cost: 55_000,
                                       location_id: location.id, date_in_stock: 10.days.ago)
      selected_scenario(vehicle: unit2, unit_price_snapshot: 65_000, unit_cost_snapshot: 55_000)

      ar   = company.chart_of_accounts.create!(account_number: '1200', name: 'Accounts Receivable',
                                               account_type: 'asset', normal_balance: 'debit')
      rev  = company.chart_of_accounts.create!(account_number: '4000', name: 'Sales Revenue',
                                               account_type: 'revenue', normal_balance: 'credit')
      cogs = company.chart_of_accounts.create!(account_number: '5000', name: 'COGS',
                                               account_type: 'expense', normal_balance: 'debit')
      company.chart_of_accounts.create!(account_number: '1210', name: 'Inventory',
                                        account_type: 'asset', normal_balance: 'debit')
      AccountingSettings.for_company(company)
                        .update!(default_ar_account: ar, default_sales_revenue_account: rev,
                                 default_cogs_account: cogs, auto_post_deals: false)

      deal.update!(stage: 'closed_won')
      deal.reload
      expect(deal.vehicle_id).to eq(unit2.id)          # unit-swapped by the write-back
      expect(deal.selling_price.to_f).to eq(65_000.0)  # scenario snapshot, NOT unit2's 80_000
      expect(deal.unit_cost.to_f).to eq(55_000.0)      # cost follows the unit
      expect(deal.home_cost.to_f).to eq(55_000.0)      # canonical accounting cost (GL reads this)

      result = Accounting::DealAccountingService.new(deal).post_closing_entries!(user: user)
      expect(result[:success]).to be(true)

      je = company.journal_entries.find(deal.reload.gl_journal_entry_id)
      cogs_line = je.journal_entry_lines.find { |l| l.chart_of_account_id == cogs.id }
      expect(cogs_line.debit_amount.to_f).to eq(55_000.0) # correct COGS for the swapped unit
    end
  end
end
