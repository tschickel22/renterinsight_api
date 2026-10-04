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

    it 'needs a cutover date' do
      post "#{base}/migrations", params: {}, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
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
                                    'active' => true, 'balance_at_cutover' => 1_102_500.0, 'confirmed' => false)
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
      expect(chase).to include('name' => 'Chase Business Checking', 'mask' => '4421', 'kind' => 'checking',
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
      expect(json['open_invoices']).to eq('count' => 10, 'total' => 52_290.4, 'ar_balance' => 52_290.4, 'difference' => 0.0)
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

    it 'lets a reader look but not start, change, post or roll back' do
      reader = rbac_user(%w[read])
      post "#{base}/migrations", params: { cutover_date: '2026-09-30' }, headers: reader, as: :json
      expect(response).to have_http_status(:forbidden)

      admin = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                           password: 'Pass1234!', company_id: rbac_company.id, role: 'platform_admin')
      import = Accounting::QboMigration::Wizard.start!(company: rbac_company, user: admin, cutover_date: QboMigrationHelpers::CUTOVER)

      get "#{base}/#{import.id}/migration", headers: reader
      expect(response).to have_http_status(:ok)
      patch "#{base}/#{import.id}/accounts", params: { confirm_suggested: true }, headers: reader, as: :json
      expect(response).to have_http_status(:forbidden)
      post "#{base}/#{import.id}/post", headers: reader, as: :json
      expect(response).to have_http_status(:forbidden)
      post "#{base}/#{import.id}/rollback", headers: reader, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses everything to a user without accounting' do
      nobody = rbac_user([])
      get "#{base}/1/migration", headers: nobody
      expect(response).to have_http_status(:forbidden)
    end
  end
end
