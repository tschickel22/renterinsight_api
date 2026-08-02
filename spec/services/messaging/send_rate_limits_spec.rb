# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::SendRateLimits do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:connection) do
    UserEmailConnection.create!(user_id: user.id, company_id: company.id, provider: 'oauth_outlook',
                                email_address: "s-#{SecureRandom.hex(3)}@example.com", is_active: true)
  end
  let(:key) { "UserEmailConnection:#{connection.id}" }

  it 'uses the provider default when nothing is configured' do
    expect(described_class.for(connection_key: key))
      .to eq('per_minute' => 10, 'per_hour' => 200, 'per_day' => 2_000)
  end

  it 'falls back to the conservative defaults for an unknown mailbox' do
    expect(described_class.for(connection_key: nil)).to eq(described_class::FALLBACK)
  end

  it 'lets a platform provider override beat the default' do
    Setting.set('Platform', 0, described_class::SETTING_KEY,
                { 'providers' => { 'oauth_outlook' => { 'per_hour' => 50 } } })

    limits = described_class.for(connection_key: key)
    expect(limits['per_hour']).to eq(50)
    expect(limits['per_minute']).to eq(10)
  end

  # This is the lever for ramping a restricted mailbox back up: pin one key low
  # without touching the provider default every other tenant inherits.
  it 'lets a per-connection override beat the provider override' do
    Setting.set('Platform', 0, described_class::SETTING_KEY,
                { 'providers' => { 'oauth_outlook' => { 'per_hour' => 200 } },
                  'connections' => { key => { 'per_minute' => 1, 'per_hour' => 3, 'per_day' => 30 } } })

    expect(described_class.for(connection_key: key))
      .to eq('per_minute' => 1, 'per_hour' => 3, 'per_day' => 30)
  end

  it 'derives spacing from the wider of the minute and hour rates' do
    Setting.set('Platform', 0, described_class::SETTING_KEY,
                { 'connections' => { key => { 'per_minute' => 1, 'per_hour' => 3, 'per_day' => 30 } } })

    # 1/min => 60s, 3/hour => 1200s. The hour rate binds.
    expect(described_class.new(connection_key: key).interval_seconds).to eq(1_200.0)
  end
end
