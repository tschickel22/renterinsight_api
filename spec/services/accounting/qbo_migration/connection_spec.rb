# frozen_string_literal: true

require 'rails_helper'

# The switch reads through the login the Connect QuickBooks button saves on
# the Company or a Location (QuickbooksOauthService), never the unused
# quickbooks_connections table.
RSpec.describe Accounting::QboMigration do
  let(:company) { Company.create!(name: "Conn-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def connect!(entity, realm)
    crypt = ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key('quickbooks_tokens', 32))
    entity.update_columns(quickbooks_realm_id: realm, quickbooks_access_token_encrypted: crypt.encrypt_and_sign('tok'),
                          quickbooks_refresh_token_encrypted: crypt.encrypt_and_sign('ref'),
                          quickbooks_token_expires_at: 1.hour.from_now)
  end

  def location!(name)
    company.locations.create!(name: name, timezone: 'America/Denver')
  end

  it 'finds nothing when QuickBooks is not connected' do
    expect(described_class.connection_for(company)).to be_nil
    expect(described_class.connected?(company)).to be(false)
    expect { described_class.adapter_for(company) }.to raise_error(described_class::Error, /not connected/)
  end

  it 'ignores a quickbooks_connections row, which nothing in the app writes' do
    QuickbooksConnection.create!(company: company, realm_id: '1', status: 'connected', access_token: 'a', refresh_token: 'r')
    expect(described_class.connection_for(company)).to be_nil
  end

  it 'uses the company login first' do
    connect!(company, '111')
    connect!(location!('Lot A'), '222')
    expect(described_class.connection_for(company)).to eq(company)
  end

  it 'uses the one connected location when the company has none' do
    loc = location!('Lot A')
    connect!(loc, '222')
    location!('Lot B')
    expect(described_class.connection_for(company)).to eq(loc)
  end

  it 'refuses to guess between two QuickBooks companies' do
    connect!(location!('Lot A'), '222')
    connect!(location!('Lot B'), '333')
    expect { described_class.connection_for(company) }.to raise_error(described_class::Error, /More than one/)
    expect(described_class.connected?(company)).to be(false)
  end

  it 'reads reports, queries and company info through the app connection' do
    connect!(company, '111')
    api = instance_double(QuickbooksApiService)
    allow(QuickbooksApiService).to receive(:new).with(company).and_return(api)
    allow(api).to receive(:get).with('reports/TrialBalance', { 'end_date' => '2026-09-30' }).and_return('Rows' => {})
    allow(api).to receive(:query).with('SELECT * FROM Account').and_return('QueryResponse' => {})
    allow(api).to receive(:get_company_info).and_return('CompanyInfo' => { 'CompanyName' => 'RI' })

    client = described_class::ConnectedClient.new(company)
    expect(client.report('TrialBalance', end_date: '2026-09-30', start_date: nil)).to eq('Rows' => {})
    expect(client.query('SELECT * FROM Account')).to eq('QueryResponse' => {})
    expect(client.company_info.dig('CompanyInfo', 'CompanyName')).to eq('RI')
  end

  it 'turns a failed token refresh into a reconnect message' do
    connect!(company, '111')
    allow(QuickbooksApiService).to receive(:new).and_raise(RuntimeError, 'Failed to refresh token: invalid_grant')
    expect { described_class::ConnectedClient.new(company).query('x') }
      .to raise_error(QuickbooksAuthError, /reconnected under Integrations/)
  end
end
