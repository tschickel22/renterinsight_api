# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# The older QuickBooks record sync (not bank feeds) stays off while a switch
# from QuickBooks is open: a draft, a posted trial or a posted live switch.
# Starting the switch turns it off, the settings screens and the sync itself
# refuse to turn it on, and rolling back puts it back as it was.
RSpec.describe 'QuickBooks record sync during a switch', type: :request do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Prairie-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let!(:books) { build_dealer_books(company) }
  let(:location) { books[:location] }
  let(:base) { '/api/v1/integrations/quickbooks' }

  around { |ex| with_qbo_fixture { ex.run } }
  before do
    stub_claude(company)
    company.update_columns(quickbooks_scope: 'location')
    location.update_columns(quickbooks_realm_id: 'realm-1',
                            quickbooks_settings: { 'auto_sync' => true,
                                                   'entities' => { 'invoices' => { 'enabled' => true, 'sync_direction' => 'to_qb' } } })
  end

  def json = JSON.parse(response.body)

  def start(trial: true)
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER, trial: trial)
    Accounting::QboMigration::Wizard.new(import)
  end

  it 'lists each location with its own connection, and turns one off' do
    get "#{base}/sync_overview", headers: headers
    expect(response).to have_http_status(:ok)
    place = json['places'].find { |p| p['type'] == 'location' }
    expect(place).to include('id' => location.id, 'connected' => true, 'entities' => ['invoices'], 'auto_sync' => true)
    expect(json['locked_reason']).to be_nil

    post "#{base}/sync_off", params: { location_id: location.id }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    settings = location.reload.quickbooks_settings
    expect(settings['auto_sync']).to be(false)
    expect(settings.dig('entities', 'invoices', 'enabled')).to be(false)
    expect(settings.dig('entities', 'invoices', 'sync_direction')).to eq('to_qb')
  end

  it 'is turned off when a switch starts and cannot be turned on or run during the trial' do
    start
    settings = location.reload.quickbooks_settings
    expect(settings['auto_sync']).to be(false)
    expect(settings.dig('entities', 'invoices', 'enabled')).to be(false)

    put "#{base}/settings/entity/invoices", params: { location_id: location.id, entity_settings: { enabled: true, sync_direction: 'to_qb' } },
                                            headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json['error']).to include('in progress')

    put "#{base}/settings", params: { location_id: location.id, settings: { auto_sync: true } }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)

    # Turning things off, or changing anything else, still works.
    put "#{base}/settings/entity/vendors", params: { location_id: location.id, entity_settings: { enabled: false, sync_direction: 'from_qb' } },
                                           headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    get "#{base}/settings/entity/invoices", params: { location_id: location.id }, headers: headers
    expect(json['locked_reason']).to be_present

    allow(QuickbooksApiService).to receive(:new).and_return(instance_double(QuickbooksApiService))
    result = QuickbooksSyncService.new(location).sync_entity_type('invoices')
    expect(result[:success]).to be(false)
    expect(result[:message]).to include('in progress')
  end

  it 'stays off after a trial posts and comes back as it was on rollback' do
    wizard = drive_to_ready(start, books)
    Accounting::QboMigration::Poster.new(wizard, user).post!
    expect(Accounting::QboMigration::OldSync.lock_message(company)).to include('trial')

    Accounting::QboMigration::Rollback.new(Accounting::QboMigration::Wizard.new(wizard.import.reload)).run!(user)
    settings = location.reload.quickbooks_settings
    expect(settings['auto_sync']).to be(true)
    expect(settings.dig('entities', 'invoices', 'enabled')).to be(true)
    expect(Accounting::QboMigration::OldSync.lock_message(company)).to be_nil

    put "#{base}/settings/entity/invoices", params: { location_id: location.id, entity_settings: { enabled: true, sync_direction: 'to_qb' } },
                                            headers: headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  it 'stays off after going live' do
    wizard = drive_to_ready(start(trial: false), books)
    Accounting::QboMigration::Poster.new(wizard, user).post!
    expect(Accounting::QboMigration::OldSync.lock_message(company)).to include('now your books')
  end
end
