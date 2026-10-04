# frozen_string_literal: true

# Shared setup for the QuickBooks switch specs: a manufactured housing dealer
# with DealerTide's seeded chart and a few bank accounts, driven against the
# recorded fixture company in spec/fixtures/quickbooks/migration
# (QBO_FIXTURE=1).
module QboMigrationHelpers
  CUTOVER = Date.new(2026, 9, 30)

  def with_qbo_fixture
    previous = ENV['QBO_FIXTURE']
    ENV['QBO_FIXTURE'] = '1'
    yield
  ensure
    ENV['QBO_FIXTURE'] = previous
  end

  # A manufactured housing company comes with the seeded chart and
  # accounting settings (AR 1110, AP 2010). This adds the bank accounts.
  def build_dealer_books(company)
    chart = company.chart_of_accounts.index_by(&:account_number)
    raise 'expected the seeded MH chart' unless chart['1010'] && chart['1110'] && chart['2010']

    banks = {
      chase: company.bank_accounts.create!(bank_name: 'Chase', institution_name: 'Chase Business Checking',
                                           account_type: 'checking', account_purpose: 'sync_only', account_mask: '4421',
                                           chart_of_account: chart['1010'], stripe_fc_status: 'active'),
      wells: company.bank_accounts.create!(bank_name: 'Wells Fargo', account_type: 'checking', account_purpose: 'sync_only',
                                           account_mask: '0912', chart_of_account: chart['1020']),
      amex: company.bank_accounts.create!(bank_name: 'American Express', account_type: 'credit_card',
                                          account_purpose: 'sync_only', account_mask: '1008')
    }
    { location: company.locations.order(:id).first, chart: chart, banks: banks }
  end

  # What a well-behaved Claude answer looks like for the fixture: maps two
  # accounts by judgment and proposes the rest as new accounts.
  def fake_claude_answer(company)
    lambda do |_system, user_text|
      payload = JSON.parse(user_text[user_text.index('{')..])
      chart = company.chart_of_accounts.index_by(&:account_number)
      maps = { '2100' => ['2110', 'medium', 'Floor plan liability for new homes'],
               '4300' => ['4140', 'high', 'Same purpose: finance reserve income'] }
      suggestions = payload['quickbooks_accounts'].map do |a|
        if (target = maps[a['number']])
          { qbo_account_id: a['qbo_account_id'], action: 'map', chart_of_account_id: chart[target[0]].id,
            reason: target[2], confidence: target[1] }
        else
          { qbo_account_id: a['qbo_account_id'], action: 'create',
            new_account: { number: a['number'] || '3950', name: a['name'], account_type: a['account_type'] },
            reason: 'No DealerTide account serves this purpose yet', confidence: 'high' }
        end
      end
      { suggestions: suggestions }.to_json
    end
  end

  def stub_claude(company)
    answer = fake_claude_answer(company)
    allow_any_instance_of(Accounting::QboMigration::AccountSuggester)
      .to receive(:request_claude) { |_instance, system, text| answer.call(system, text) }
  end

  # Runs every step the person would, leaving the migration ready to post.
  def drive_to_ready(wizard, books)
    Accounting::QboMigration::AccountSuggester.new(wizard).run!
    wizard.update_accounts!([], confirm_suggested: true)
    wizard.update_banks!([
                           { qbo_account_id: '1', bank_account_id: books[:banks][:chase].id, closed: false },
                           { qbo_account_id: '2', bank_account_id: books[:banks][:wells].id, closed: false },
                           { qbo_account_id: '14', bank_account_id: books[:banks][:amex].id, closed: false }
                         ])
    pending = wizard.account_rows.select { |r| !r['confirmed'] && r['choice'].present? }
                    .map { |r| { qbo_account_id: r['qbo_account_id'], confirmed: true } }
    wizard.update_accounts!(pending)
    banks = wizard.uncleared_json[:banks].index_by { |b| b[:qbo_account_id] }
    wizard.update_uncleared!([
                               { qbo_account_id: '1', statement_balance: '181300.25', items: banks['1'][:items] },
                               { qbo_account_id: '2', statement_balance: '24310.00', items: [] },
                               { qbo_account_id: '14', statement_balance: '6700.00', items: banks['14'][:items] }
                             ])
    wizard.preview_json
    wizard
  end
end
