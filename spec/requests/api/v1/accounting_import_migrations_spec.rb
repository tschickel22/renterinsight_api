# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# The QuickBooks switch endpoints (qbo_migration_contract.md), driven
# against the recorded fixture company with QBO_FIXTURE=1.
RSpec.describe 'Api::V1 accounting import migrations', type: :request do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Prairie-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let!(:books) { build_dealer_books(company) }
  let(:base) { '/api/v1/accounting_imports' }

  around { |ex| with_qbo_fixture { ex.run } }
  before { stub_claude(company) }

  def json = JSON.parse(response.body)

  def start_migration
    post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: headers, as: :json
    json.dig('migration', 'id')
  end

  describe 'POST /migrations' do
    it 'starts a draft from the fixture company' do
      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      m = json['migration']
      expect(m).to include('status' => 'draft', 'source_type' => 'quickbooks_online', 'cutover_date' => '2026-09-30',
                           'quickbooks_company_name' => 'Prairie Wind Homes LLC', 'posted_at' => nil,
                           'rollback_available' => false)
      expect(m['steps']['connect']).to eq('done' => true)
      expect(m['steps']['banks']).to eq('done' => false, 'matched' => 0, 'problems' => 0, 'total' => 3)
      expect(m['steps']['lists']).to eq('done' => true, 'customers' => 10, 'vendors' => 5)
      expect(m['steps']['accounts']).to include('done' => false, 'confirmed' => 0)
      expect(m['blockers']).to include(match(/accounts with a balance are not confirmed yet/), 'Chase Operating Checking is not matched to a bank account')
    end

    it 'returns the existing draft instead of starting another' do
      id = start_migration
      post "#{base}/migrations", params: { cutover_date: '2026-08-31' }, headers: headers, as: :json
      expect(json.dig('migration', 'id')).to eq(id)
      expect(company.accounting_imports.count).to eq(1)
    end

    it 'refuses without a QuickBooks connection outside fixture mode' do
      ENV['QBO_FIXTURE'] = nil
      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/QuickBooks Online is not connected/)
      expect(company.accounting_imports.count).to eq(0)
    end

    it 'refuses a cutover date in the future, judged by the dealer\'s own calendar' do
      tomorrow = company.today + 1
      post "#{base}/migrations", params: { cutover_date: tomorrow.iso8601 }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/can't be in the future/)
      expect(company.accounting_imports.count).to eq(0)
    end

    it 'refuses moving a draft to a future cutover date and keeps the old one' do
      id = start_migration
      patch "#{base}/#{id}/migration", params: { cutover_date: (company.today + 20).iso8601 }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/can't be in the future/)
      expect(company.accounting_imports.find(id).cutover_date).to eq(Date.new(2026, 9, 30))
    end

    it 'allows today as the cutover' do
      post "#{base}/migrations", params: { cutover_date: company.today.iso8601 }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
    end

    it 'needs a cutover date' do
      post "#{base}/migrations", params: {}, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET / (import history)' do
    it 'marks the switch so it can be reopened, without sending the QuickBooks data' do
      id = start_migration
      company.accounting_imports.create!(user: user, source_type: 'csv', status: 'completed')
      get base, headers: headers
      expect(response).to have_http_status(:ok)
      items = json['items'].index_by { |i| i['id'] }
      expect(items[id]).to include('migration' => true, 'status' => 'draft', 'source_type' => 'quickbooks_online')
      expect(items[id]).not_to have_key('import_config')
      expect(items.values.find { |i| i['source_type'] == 'csv' }).to include('migration' => false)
    end
  end

  describe 'GET and PATCH /:id/migration' do
    it 'changes the cutover date and moves the feed start dates with it' do
      id = start_migration
      patch "#{base}/#{id}/banks", params: { matches: [{ qbo_account_id: '1', bank_account_id: books[:banks][:chase].id, closed: false }] },
                                   headers: headers, as: :json
      expect(books[:banks][:chase].reload.feed_start_date).to eq(Date.new(2026, 10, 1))

      patch "#{base}/#{id}/migration", params: { cutover_date: '2026-09-29' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json.dig('migration', 'cutover_date')).to eq('2026-09-29')
      expect(books[:banks][:chase].reload.feed_start_date).to eq(Date.new(2026, 9, 30))

      get "#{base}/#{id}/migration", headers: headers
      expect(json.dig('migration', 'cutover_date')).to eq('2026-09-29')
    end
  end

  describe 'accounts' do
    it 'lists rows with balances at cutover and the DealerTide chart' do
      id = start_migration
      get "#{base}/#{id}/accounts", headers: headers
      expect(response).to have_http_status(:ok)

      rows = json['accounts'].index_by { |r| r['qbo_account_id'] }
      expect(rows['15']).to include('qbo_name' => 'Floor Plan Payable - Triad', 'qbo_number' => '2100',
                                    'qbo_type' => 'Other Current Liability', 'qbo_sub_type' => 'LoanPayable',
                                    'active' => true, 'account_type' => 'liability', 'balance_at_cutover' => 1_102_500.0, 'confirmed' => false)
      expect(rows['10']).to include('active' => false, 'balance_at_cutover' => 5000.0) # inactive with a balance
      expect(rows.keys).not_to include('3', '30') # inactive and empty
      expect(json['dealertide_accounts'].first.keys).to match_array(%w[id number name account_type sub_type])
      expect(json['dealertide_accounts'].map { |a| a['number'] }).not_to include('1000') # headers excluded
    end

    it 'suggests exact matches without AI and the rest in one batched call' do
      id = start_migration
      answer = fake_claude_answer(company)
      expect_any_instance_of(Accounting::QboMigration::AccountSuggester).to receive(:request_claude).once { |_i, s, t| answer.call(s, t) }
      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      rows = json['accounts'].index_by { |r| r['qbo_account_id'] }
      ar = company.chart_of_accounts.find_by!(account_number: '1110')
      expect(rows['4']['suggestion']).to include('action' => 'map', 'chart_of_account_id' => ar.id, 'source' => 'exact')
      expect(rows['15']['suggestion']).to include('action' => 'map', 'source' => 'ai', 'confidence' => 'medium')
      expect(rows['33']['suggestion']).to include('action' => 'create', 'source' => 'ai')
      expect(rows['33']['choice']).to include('action' => 'create')
      expect(rows.values.map { |r| r['suggestion'] }).to all(be_present)
    end

    # Browser test 2026-10-03: a rerun gave a row a new suggestion, but its
    # choice stayed on the old one, so the screen showed the old account.
    it 'moves a choice that only followed the old suggestion, and keeps one the person picked' do
      id = start_migration
      answer = fake_claude_answer(company)
      allow_any_instance_of(Accounting::QboMigration::AccountSuggester).to receive(:request_claude) { |_i, s, t| answer.call(s, t) }
      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      first = json['accounts'].index_by { |r| r['qbo_account_id'] }

      wrong = company.chart_of_accounts.find_by!(account_number: '6020')
      import = company.accounting_imports.find(id)
      rows = import.import_config['accounts']
      followed = rows.find { |r| r['qbo_account_id'] == '15' }
      followed['suggestion'] = { 'action' => 'map', 'chart_of_account_id' => wrong.id, 'source' => 'exact', 'confidence' => 'high' }
      followed['choice'] = { 'action' => 'map', 'chart_of_account_id' => wrong.id }
      picked = rows.find { |r| r['qbo_account_id'] == '33' }
      picked['choice'] = { 'action' => 'map', 'chart_of_account_id' => wrong.id }
      import.update!(import_config: import.import_config)

      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      after = json['accounts'].index_by { |r| r['qbo_account_id'] }
      expect(after['15']['choice']).to eq(first['15']['choice'])
      expect(after['33']['choice']).to eq('action' => 'map', 'chart_of_account_id' => wrong.id)
    end

    it 'never overwrites a confirmed row' do
      id = start_migration
      payroll = company.chart_of_accounts.find_by!(account_number: '6020')
      patch "#{base}/#{id}/accounts", params: { accounts: [{ qbo_account_id: '35', action: 'map', chart_of_account_id: payroll.id, confirmed: true }] },
                                      headers: headers, as: :json
      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      row = json['accounts'].find { |r| r['qbo_account_id'] == '35' }
      expect(row['choice']).to eq('action' => 'map', 'chart_of_account_id' => payroll.id)
      expect(row['confirmed']).to be(true)
      expect(row['suggestion']).to be_nil
    end

    it 'keeps the wizard working when the AI call fails' do
      id = start_migration
      allow_any_instance_of(Accounting::QboMigration::AccountSuggester).to receive(:request_claude).and_raise('timeout')
      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['note']).to match(/not available/)
      rows = json['accounts'].index_by { |r| r['qbo_account_id'] }
      expect(rows['4']['suggestion']['source']).to eq('exact')
      expect(rows['15']['suggestion']).to be_nil
    end

    it 'maps, creates and confirms in one PATCH, and confirms suggestions in bulk' do
      id = start_migration
      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      floor = company.chart_of_accounts.find_by!(account_number: '2110')
      patch "#{base}/#{id}/accounts",
            params: { accounts: [
              { qbo_account_id: '15', action: 'map', chart_of_account_id: floor.id, confirmed: true },
              { qbo_account_id: '16', action: 'create', confirmed: true,
                new_account: { number: '2140', name: 'Floor Plan - 21st Mortgage', account_type: 'liability', sub_type: 'current_liability' } }
            ] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      rows = json['accounts'].index_by { |r| r['qbo_account_id'] }
      expect(rows['15']).to include('confirmed' => true, 'choice' => { 'action' => 'map', 'chart_of_account_id' => floor.id })
      expect(rows['16']['choice']['new_account']).to include('number' => '2140', 'account_type' => 'liability')
      expect(json['migration']['steps']['accounts']['confirmed']).to eq(2)

      patch "#{base}/#{id}/accounts", params: { confirm_suggested: true }, headers: headers, as: :json
      confirmed = json['accounts'].count { |r| r['confirmed'] }
      expect(confirmed).to be > 30
    end

    it 'refuses a header, another company\'s account and a taken number' do
      id = start_migration
      header = company.chart_of_accounts.find_by!(account_number: '1000')
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}", industry: 'manufactured_housing')
      foreign = other.chart_of_accounts.find_by!(account_number: '1010')

      patch "#{base}/#{id}/accounts", params: { accounts: [{ qbo_account_id: '1', action: 'map', chart_of_account_id: header.id }] },
                                      headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/header/)

      patch "#{base}/#{id}/accounts", params: { accounts: [{ qbo_account_id: '1', action: 'map', chart_of_account_id: foreign.id }] },
                                      headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      patch "#{base}/#{id}/accounts", params: { accounts: [{ qbo_account_id: '9', action: 'create', new_account: { number: '1310', name: 'X', account_type: 'asset' } }] },
                                      headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/already taken/)
    end
  end

  describe 'bank match checks' do
    it 'drops the GL pin when a matched bank is closed instead' do
      id = start_migration
      get "#{base}/#{id}/banks", headers: headers
      checking = json['qbo_bank_accounts'].find { |b| b['kind'] == 'bank' }
      patch "#{base}/#{id}/banks", params: { matches: [{ qbo_account_id: checking['qbo_account_id'], bank_account_id: books[:banks][:chase].id }] },
                                   headers: headers, as: :json
      pinned = json_accounts_row(id, checking['qbo_account_id'])
      expect(pinned).to include('bank_match' => true, 'confirmed' => true)

      patch "#{base}/#{id}/banks", params: { matches: [{ qbo_account_id: checking['qbo_account_id'], bank_account_id: nil, closed: true }] },
                                   headers: headers, as: :json
      row = json_accounts_row(id, checking['qbo_account_id'])
      expect(row).to include('bank_match' => false, 'confirmed' => false, 'choice' => nil)
    end

    # Browser test 2026-10-03: a card matched to a checking account, and two
    # QuickBooks accounts on one GL, both reached the preview without a word.
    it 'flags a card matched to a checking account and two accounts sharing a GL, and blocks posting' do
      id = start_migration
      get "#{base}/#{id}/banks", headers: headers
      qbo = json['qbo_bank_accounts']
      card = qbo.find { |b| b['kind'] == 'credit_card' }
      checking = qbo.find { |b| b['kind'] == 'bank' }
      second_checking = company.bank_accounts.create!(bank_name: 'Chase Two', account_type: 'checking', account_purpose: 'sync_only',
                                                      account_mask: '9999', chart_of_account: books[:banks][:chase].chart_of_account)
      patch "#{base}/#{id}/banks", params: { matches: [
        { qbo_account_id: checking['qbo_account_id'], bank_account_id: books[:banks][:chase].id, closed: false },
        { qbo_account_id: card['qbo_account_id'], bank_account_id: second_checking.id, closed: false }
      ] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      rows = json['qbo_bank_accounts'].index_by { |b| b['qbo_account_id'] }
      expect(rows[card['qbo_account_id']]['problems'].join).to include('credit card in QuickBooks', 'asset account')
      expect(rows[checking['qbo_account_id']]['problems'].join).to include('same GL account')
      expect(json['migration']['steps']['banks']['done']).to be(false)
      expect(json['migration']['blockers'].join).to include('credit card in QuickBooks')
    end
  end

  def json_accounts_row(id, qbo_account_id)
    get "#{base}/#{id}/accounts", headers: headers
    json['accounts'].find { |r| r['qbo_account_id'] == qbo_account_id }
  end

  describe 'banks' do
    it 'lists QuickBooks banks and cards with the DealerTide bank accounts' do
      id = start_migration
      get "#{base}/#{id}/banks", headers: headers
      qbo = json['qbo_bank_accounts'].index_by { |b| b['qbo_account_id'] }
      expect(qbo['1']).to include('name' => 'Chase Operating Checking', 'kind' => 'bank', 'balance_at_cutover' => 182_450.25, 'match' => nil)
      expect(qbo['14']).to include('kind' => 'credit_card', 'balance_at_cutover' => 6842.17)
      chase = json['bank_accounts'].find { |b| b['id'] == books[:banks][:chase].id }
      expect(chase).to include('name' => 'Chase (Chase Business Checking)', 'mask' => '4421', 'kind' => 'checking',
                               'feed_connected' => true, 'feed_start_date' => nil)
    end

    it 'matches, sets the feed start date and pins the account mapping' do
      id = start_migration
      patch "#{base}/#{id}/banks", params: { matches: [
        { qbo_account_id: '1', bank_account_id: books[:banks][:chase].id, closed: false },
        { qbo_account_id: '2', bank_account_id: nil, closed: true }
      ] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['migration']['steps']['banks']).to include('matched' => 2, 'total' => 3)
      expect(json['qbo_bank_accounts'].find { |b| b['qbo_account_id'] == '2' }['match']).to eq('bank_account_id' => nil, 'closed' => true)
      expect(books[:banks][:chase].reload.feed_start_date).to eq(Date.new(2026, 10, 1))

      get "#{base}/#{id}/accounts", headers: headers
      row = json['accounts'].find { |r| r['qbo_account_id'] == '1' }
      expect(row).to include('confirmed' => true, 'bank_match' => true,
                             'choice' => { 'action' => 'map', 'chart_of_account_id' => books[:chart]['1010'].id })
    end

    it 'creates a feed-only bank account for every unmatched QuickBooks bank and card, and matches it' do
      id = start_migration
      patch "#{base}/#{id}/banks", params: { matches: [{ qbo_account_id: '1', bank_account_id: books[:banks][:chase].id }] },
                                   headers: headers, as: :json
      unmatched = json['qbo_bank_accounts'].reject { |b| b['match'] }.map { |b| b['qbo_account_id'] }
      expect(unmatched).not_to be_empty

      expect do
        post "#{base}/#{id}/banks/create", headers: headers, as: :json
      end.to change { company.bank_accounts.count }.by(unmatched.size)
      expect(response).to have_http_status(:ok)
      expect(json).to include('created' => unmatched.size, 'matched_existing' => 0)
      qbo = json['qbo_bank_accounts'].index_by { |b| b['qbo_account_id'] }
      expect(qbo['1']['match']).to include('bank_account_id' => books[:banks][:chase].id)
      expect(json['qbo_bank_accounts']).to all(satisfy { |b| b['match'] && b['match']['bank_account_id'] })

      # Each new account listed once (a lazily loaded list once held it twice).
      expect(json['bank_accounts'].map { |b| b['id'] }).to eq(json['bank_accounts'].map { |b| b['id'] }.uniq)
      card = company.bank_accounts.find(qbo['14']['match']['bank_account_id'])
      expect(card).to have_attributes(bank_name: 'Amex Business Card', account_type: 'credit_card', account_purpose: 'sync_only',
                                      routing_number: nil, chart_of_account_id: nil)
      expect(card.feed_start_date).to eq(Date.new(2026, 10, 1))

      expect { post "#{base}/#{id}/banks/create", headers: headers, as: :json }.not_to(change { company.bank_accounts.count })
      expect(json['created']).to eq(0)
    end

    it 'matches an unmatched bank account with the same last four instead of making another' do
      id = start_migration
      import = company.accounting_imports.find(id)
      cfg = import.import_config
      cfg['banks'].find { |b| b['qbo_account_id'] == '2' }['name'] = 'Wells Fargo Payroll 0912'
      import.update!(import_config: cfg)

      post "#{base}/#{id}/banks/create", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['matched_existing']).to eq(1)
      wells = json['qbo_bank_accounts'].find { |b| b['qbo_account_id'] == '2' }
      expect(wells['match']['bank_account_id']).to eq(books[:banks][:wells].id)
    end

    it 'refuses another company\'s bank account' do
      id = start_migration
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
      foreign = other.bank_accounts.create!(bank_name: 'Theirs', account_type: 'checking', account_purpose: 'sync_only')
      patch "#{base}/#{id}/banks", params: { matches: [{ qbo_account_id: '1', bank_account_id: foreign.id }] }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(foreign.reload.feed_start_date).to be_nil
    end
  end

  describe 'uncleared' do
    it 'suggests items from QuickBooks and ties once the statement balance is entered' do
      id = start_migration
      patch "#{base}/#{id}/banks", params: { matches: [{ qbo_account_id: '1', bank_account_id: books[:banks][:chase].id }] },
                                   headers: headers, as: :json
      get "#{base}/#{id}/uncleared", headers: headers
      bank = json['banks'].first
      expect(bank).to include('qbo_account_id' => '1', 'balance_at_cutover' => 182_450.25, 'statement_balance' => nil, 'difference' => nil)
      expect(bank['items'].map { |i| [i['kind'], i['amount']] }).to eq([['check', 1200.0], ['check', 850.0], ['deposit', 3200.0]])

      put "#{base}/#{id}/uncleared", params: { banks: [{ qbo_account_id: '1', statement_balance: 181_300.25, items: bank['items'] }] },
                                     headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['banks'].first['difference']).to eq(0.0)

      items = bank['items'].first(2) + [{ date: '2026-09-27', kind: 'deposit', payee: 'Walk in', amount: 50 }]
      put "#{base}/#{id}/uncleared", params: { banks: [{ qbo_account_id: '1', items: items }] }, headers: headers, as: :json
      # 182450.25 - 181300.25 + 2050 - 50
      expect(json['banks'].first['difference']).to eq(3150.0)
      expect(json['banks'].first['items'].last['id']).to be_present

      put "#{base}/#{id}/uncleared", params: { banks: [{ qbo_account_id: '1', items: [{ date: '2026-10-05', kind: 'check', amount: 5 }] }] },
                                     headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/after the cutover/)
    end
  end

  describe 'statement balances from the bank feed' do
    let(:service) { instance_double(StripeBankFeedService) }
    let(:ready) do
      ->(balance) { { status: 'ready', balance: BigDecimal(balance), current: BigDecimal('190000'), lines_after: 4,
                      as_of: Time.utc(2026, 11, 12, 15), old_date: false } }
    end

    before do
      books[:banks][:chase].update!(stripe_fc_account_id: 'fca_chase', stripe_fc_status: 'active')
      books[:banks][:amex].update!(stripe_fc_account_id: 'fca_amex', stripe_fc_status: 'active')
      allow(StripeBankFeedService).to receive(:new).and_return(service)
    end

    def match_all(id)
      patch "#{base}/#{id}/banks", params: { matches: [
        { qbo_account_id: '1', bank_account_id: books[:banks][:chase].id },
        { qbo_account_id: '2', bank_account_id: books[:banks][:wells].id },
        { qbo_account_id: '14', bank_account_id: books[:banks][:amex].id }
      ] }, headers: headers, as: :json
    end

    it 'fills blank statement balances from the bank and ties, a card as what was owed' do
      allow(service).to receive(:balance_on) do |ba, date, zone:|
        expect(date).to eq(Date.new(2026, 9, 30))
        expect(zone.name).to eq(ActiveSupport::TimeZone[company.time_zone].name)
        ba.account_type == 'credit_card' ? ready.call('-6842.17') : ready.call('181300.25')
      end
      id = start_migration
      match_all(id)

      post "#{base}/#{id}/uncleared/bank_balances", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      banks = json['banks'].index_by { |b| b['qbo_account_id'] }
      expect(banks['1']).to include('statement_balance' => 181_300.25, 'statement_from_bank' => true, 'difference' => 0.0)
      expect(banks['1']['bank_balance']).to include('status' => 'ready', 'amount' => 181_300.25, 'lines_after' => 4,
                                                    'as_of' => '2026-11-12T15:00:00Z')
      expect(banks['14']).to include('statement_balance' => 6842.17, 'statement_from_bank' => true)
      expect(banks['14']['bank_balance']['current']).to eq(-190_000.0)
      # Wells Fargo has no feed: left for the person to type.
      expect(banks['2']).to include('statement_balance' => nil, 'statement_from_bank' => false)
      expect(banks['2']['bank_balance']).to include('status' => 'not_connected')
      expect(service).to have_received(:balance_on).twice

      get "#{base}/#{id}/migration", headers: headers
      expect(json.dig('migration', 'steps', 'uncleared', 'done')).to be(false) # Wells still blank
    end

    it 'never overwrites a balance the person typed, but updates one it filled itself' do
      amounts = { 'checking' => '181300.25' }
      allow(service).to receive(:balance_on) { |ba, *_| ba.account_type == 'credit_card' ? { status: 'pending' } : ready.call(amounts['checking']) }
      id = start_migration
      match_all(id)
      post "#{base}/#{id}/uncleared/bank_balances", headers: headers, as: :json
      expect(json['banks'].find { |b| b['qbo_account_id'] == '14' }).to include('statement_balance' => nil)
      expect(json['banks'].find { |b| b['qbo_account_id'] == '14' }['bank_balance']).to include('status' => 'pending')

      amounts['checking'] = '181290.25'
      post "#{base}/#{id}/uncleared/bank_balances", headers: headers, as: :json
      expect(json['banks'].first).to include('statement_balance' => 181_290.25, 'statement_from_bank' => true)

      put "#{base}/#{id}/uncleared", params: { banks: [{ qbo_account_id: '1', statement_balance: 181_000 }] }, headers: headers, as: :json
      expect(json['banks'].first).to include('statement_balance' => 181_000.0, 'statement_from_bank' => false)
      post "#{base}/#{id}/uncleared/bank_balances", headers: headers, as: :json
      expect(json['banks'].first).to include('statement_balance' => 181_000.0, 'statement_from_bank' => false)
      expect(json['banks'].first['bank_balance']['amount']).to eq(181_290.25)

      # Typing the bank's own figure counts as from the bank again.
      put "#{base}/#{id}/uncleared", params: { banks: [{ qbo_account_id: '1', statement_balance: '181290.25' }] }, headers: headers, as: :json
      expect(json['banks'].first['statement_from_bank']).to be(true)
    end

    it 'keeps going when bank balances are not set up at all' do
      allow(StripeBankFeedService).to receive(:new).and_raise('Stripe secret key not configured')
      id = start_migration
      match_all(id)
      post "#{base}/#{id}/uncleared/bank_balances", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['banks'].first['bank_balance']).to include('status' => 'unavailable')
      expect(json['banks'].first['statement_balance']).to be_nil
    end

    it 'refuses once the switch is posted' do
      allow(service).to receive(:balance_on).and_return(ready.call('1'))
      id = start_migration
      company.accounting_imports.find(id).update_columns(status: 'completed')
      post "#{base}/#{id}/uncleared/bank_balances", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'preview, post and rollback' do
    it 'refuses to post with the blockers, then posts and rolls back' do
      id = start_migration
      post "#{base}/#{id}/post", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['blockers']).to be_present

      drive_to_ready(Accounting::QboMigration::Wizard.new(company.accounting_imports.find(id)), books)
      get "#{base}/#{id}/preview", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json).to include('can_post' => true, 'blockers' => [], 'equity_plug' => 0.0, 'differences' => [])
      expect(json['open_invoices']).to eq('count' => 10, 'total' => 52_290.4, 'ar_balance' => 52_290.4, 'difference' => 0.0,
                                          'invoices_total' => 52_290.4, 'customer_credits_total' => 0.0,
                                          'customer_credits_count' => 0, 'unapplied_customer_credits' => 0.0)
      expect(json['totals']['debit']).to eq(json['totals']['credit'])
      expect(json['totals']['carries_every_balance']).to be(true)
      table_debits = json['trial_balance'].sum { |r| r['debit'] }
      expect(json['totals']['debit']).to be_within(0.005).of(table_debits) # totals are the table's, netted per account
      expect(json['trial_balance'].first.keys).to match_array(%w[dealertide_account qbo_accounts debit credit])

      post "#{base}/#{id}/post", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['migration']).to include('status' => 'posted', 'rollback_available' => true)
      expect(json['migration']['posted_at']).to be_present
      expect(json['results']['open_invoices']['created']).to eq(10)

      patch "#{base}/#{id}/migration", params: { cutover_date: '2026-08-31' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      post "#{base}/#{id}/rollback", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['migration']).to include('status' => 'rolled_back', 'rollback_available' => false)

      post "#{base}/#{id}/rollback", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'trial, then go live (E101)' do
    let(:cash) { books[:chart]['1010'] }
    let(:sales) { company.chart_of_accounts.find_by!(account_type: 'revenue', is_header: [false, nil]) }

    def entry(date, memo)
      Accounting::ManualPostingService.new(company).post_simple!(
        debit_account: cash, credit_account: sales, amount: 100, memo: memo, entry_date: date
      )
    end

    def bank_line(date, desc)
      company.bank_transactions.create!(bank_account: books[:banks][:chase], transaction_date: date, amount: 50,
                                        description: desc, status: 'unmatched')
    end

    def post_trial
      post "#{base}/migrations", params: { cutover_date: '2026-09-30', trial: true }, headers: headers, as: :json
      id = json.dig('migration', 'id')
      expect(json['migration']['trial']).to be(true)
      drive_to_ready(Accounting::QboMigration::Wizard.new(company.accounting_imports.find(id)), books)
      post "#{base}/#{id}/post", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['migration']).to include('trial' => true)
      expect(json['migration']['trial_started_at']).to be_present
      id
    end

    def finish_uncleared(id)
      wizard = Accounting::QboMigration::Wizard.new(company.accounting_imports.find(id))
      banks = wizard.uncleared_json[:banks].index_by { |b| b[:qbo_account_id] }
      wizard.update_uncleared!([
                                 { qbo_account_id: '1', statement_balance: '181300.25', items: banks['1'][:items] },
                                 { qbo_account_id: '2', statement_balance: '24310.00', items: [] },
                                 { qbo_account_id: '14', statement_balance: '6700.00', items: banks['14'][:items] }
                               ])
    end

    it 'goes live from a trial with every match carried, settling trial activity by the cutover date' do
      older = entry(Date.new(2026, 10, 10), 'Kept here before the trial')
      older.update_column(:created_at, 2.days.ago)
      # A line booked before the trial, by an entry that stays: left alone.
      booked_before = bank_line(Date.new(2026, 10, 10), 'Booked before the trial')
      booked_before.update_columns(status: 'matched', matched_journal_entry_id: older.id)
      trial_id = post_trial
      before = entry(Date.new(2026, 10, 15), 'Deal approved during the trial')
      after = entry(Date.new(2026, 11, 5), 'After the final cutover')
      early_line = bank_line(Date.new(2026, 10, 20), 'Deposit in October')
      # A line categorized during the trial, by an entry going live voids: excluded with it.
      booked_in_trial = bank_line(Date.new(2026, 10, 15), 'Categorized during the trial')
      booked_in_trial.update_columns(status: 'matched', matched_journal_entry_id: before.id)
      late_line = bank_line(Date.new(2026, 11, 3), 'Deposit in November')

      post "#{base}/#{trial_id}/go_live", params: { cutover_date: '2026-10-31' }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      live = json['migration']
      expect(live).to include('status' => 'draft', 'trial' => false, 'from_import_id' => trial_id, 'cutover_date' => '2026-10-31')
      expect(live['trial_started_at']).to be_present
      expect(live['steps']['banks']).to include('done' => true, 'matched' => 3)
      expect(live['steps']['accounts']['done']).to be(true)
      expect(company.accounting_imports.find(trial_id).status).to eq('rolled_back')
      expect(books[:banks][:chase].reload.feed_start_date).to eq(Date.new(2026, 11, 1))

      finish_uncleared(live['id'])
      get "#{base}/#{live['id']}/preview", headers: headers
      expect(json['can_post']).to be(true)
      expect(json['settlement']['entries'].map { |e| e['id'] }).to eq([before.id])
      expect(json['settlement']['bank_lines'].map { |l| l['id'] }).to eq([booked_in_trial.id, early_line.id])
      expect(json['unconnected_banks'].map { |b| b['qbo_account_id'] }).to match_array(%w[2 14])

      post "#{base}/#{live['id']}/post", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json['migration']['settled']).to include('voided_entry_ids' => [before.id],
                                                      'excluded_bank_line_ids' => [booked_in_trial.id, early_line.id])
      expect(booked_before.reload.status).to eq('matched')
      expect(before.reload.is_void).to be(true)
      expect(after.reload.is_void).to be(false)
      expect(older.reload.is_void).to be(false)
      expect(early_line.reload).to have_attributes(status: 'excluded', excluded_reason: match(/Recorded in QuickBooks/))
      expect(late_line.reload.status).to eq('unmatched')
      # The trial's opening entry stays voided: its reversal is never settled.
      trial_entry = company.journal_entries.find(company.accounting_imports.find(trial_id).import_config.dig('posted', 'journal_entry_id'))
      expect(trial_entry.is_void).to be(true)
      expect(trial_entry.reversed_by.is_void).to be(false)
    end

    it 'updates a trial to a newer date and stays a trial, settling nothing' do
      trial_id = post_trial
      during = entry(Date.new(2026, 10, 15), 'During the trial')
      post "#{base}/#{trial_id}/go_live", params: { cutover_date: '2026-10-31', trial: true }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(json['migration']).to include('trial' => true, 'from_import_id' => trial_id)
      new_id = json['migration']['id']
      finish_uncleared(new_id)
      get "#{base}/#{new_id}/preview", headers: headers
      expect(json['settlement']).to eq('entries' => [], 'bank_lines' => [])
      post "#{base}/#{new_id}/post", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(during.reload.is_void).to be(false)
    end

    it 'refuses a go-live date before the trial cutover, in the future, or from a switch that is not a posted trial' do
      trial_id = post_trial
      post "#{base}/#{trial_id}/go_live", params: { cutover_date: '2026-08-31' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/can't be before the trial/)
      post "#{base}/#{trial_id}/go_live", params: { cutover_date: (company.today + 3).iso8601 }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(company.accounting_imports.find(trial_id).status).to eq('posted') # the rollback was undone with it

      company.accounting_imports.find(trial_id).update!(status: 'rolled_back')
      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: headers, as: :json
      live_id = json.dig('migration', 'id')
      post "#{base}/#{live_id}/go_live", params: { cutover_date: '2026-10-31' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/Only a posted trial/)
    end

    it 'suggests an account that carries the QuickBooks id as an exact match' do
      id = start_migration
      row = company.accounting_imports.find(id).import_config['accounts'].find { |r| r['dt_account_type'] == 'expense' }
      acct = company.chart_of_accounts.create!(account_number: '6999', name: 'Something else entirely', account_type: 'expense',
                                               is_active: true, qbo_account_id: row['qbo_account_id'])
      post "#{base}/#{id}/accounts/suggest", headers: headers, as: :json
      got = json['accounts'].find { |r| r['qbo_account_id'] == row['qbo_account_id'] }
      expect(got['suggestion']).to include('chart_of_account_id' => acct.id, 'source' => 'exact')
    end
  end

  describe 'tenant isolation' do
    it "cannot see or touch another company's migration" do
      id = start_migration
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}", industry: 'manufactured_housing')
      outsider = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'X',
                              password: 'Pass1234!', company_id: other.id, role: 'platform_admin')
      their = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: outsider.id, company_id: other.id)}" }

      get "#{base}/#{id}/migration", headers: their
      expect(response).to have_http_status(:not_found)
      get "#{base}/#{id}/accounts", headers: their
      expect(response).to have_http_status(:not_found)
      post "#{base}/#{id}/post", headers: their, as: :json
      expect(response).to have_http_status(:not_found)
      post "#{base}/#{id}/rollback", headers: their, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'does not treat an ordinary import as a migration' do
      plain = company.accounting_imports.create!(user: user, source_type: 'csv', status: 'completed')
      get "#{base}/#{plain.id}/migration", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'permissions' do
    let(:rbac_company) do
      Company.create!(name: "Rbac-#{SecureRandom.hex(4)}", industry: 'manufactured_housing', use_rbac_system: true)
    end

    before do
      Resource.seed_defaults
      Action.seed_defaults
      Scope.seed_defaults
    end

    def rbac_user(actions)
      role = Role.create!(company_id: rbac_company.id, key: "r-#{SecureRandom.hex(3)}", name: 'Reader', tier: 'company', active: true)
      actions.each do |action|
        RolePermission.create!(role: role, resource: Resource.find_by!(key: 'accounting'), action: Action.find_by!(key: action),
                               scope: Scope.find_by!(key: 'all'), granted: true)
      end
      u = rbac_company.users.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'O',
                                     password: 'Pass1234!', role: 'user')
      u.user_role_assignments.create!(role: role, company_id: rbac_company.id, tier: 'company')
      Rails.cache.clear
      { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: rbac_company.id)}" }
    end

    # Company admins and platform admins. The accounting RBAC checks stay
    # behind it.
    it 'keeps the switch from staff who are not admins, even with full accounting rights' do
      dealer = rbac_user(%w[read create update delete])
      admin = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                           password: 'Pass1234!', company_id: rbac_company.id, role: 'platform_admin')
      import = Accounting::QboMigration::Wizard.start!(company: rbac_company, user: admin, cutover_date: QboMigrationHelpers::CUTOVER)

      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: dealer, as: :json
      expect(response).to have_http_status(:forbidden)
      get "#{base}/#{import.id}/migration", headers: dealer
      expect(response).to have_http_status(:forbidden)
      patch "#{base}/#{import.id}/accounts", params: { confirm_suggested: true }, headers: dealer, as: :json
      expect(response).to have_http_status(:forbidden)
      post "#{base}/#{import.id}/post", headers: dealer, as: :json
      expect(response).to have_http_status(:forbidden)
      post "#{base}/#{import.id}/rollback", headers: dealer, as: :json
      expect(response).to have_http_status(:forbidden)

      get base, headers: dealer
      expect(response).to have_http_status(:ok)
    end

    it 'lets a platform admin run it while impersonating a dealer user' do
      dealer = company.users.create!(email: "d-#{SecureRandom.hex(4)}@example.com", first_name: 'D', last_name: 'U',
                                     password: 'Pass1234!', role: 'company_admin')
      as_dealer = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id, impersonated_by: user.id)}" }

      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: as_dealer, as: :json
      expect(response).to have_http_status(:created)
    end

    it "lets the dealer's own company admin run it" do
      dealer = company.users.create!(email: "ca-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'A',
                                     password: 'Pass1234!', role: 'company_admin')
      as_admin = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}" }

      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: as_admin, as: :json
      expect(response).to have_http_status(:created)
    end

    it 'refuses everything to a user without accounting' do
      nobody = rbac_user([])
      get "#{base}/1/migration", headers: nobody
      expect(response).to have_http_status(:forbidden)
    end
  end
end
