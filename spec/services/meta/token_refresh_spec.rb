# frozen_string_literal: true

require 'rails_helper'

# Every Meta refresh path stamped the expiry as `Time.current + expires_in`.
# Graph leaves expires_in out for a token that does not expire, `nil.to_i` is
# 0, and the connection was therefore marked expired the instant it was
# renewed. Production integration 2 on 2026-09-21 had token_expires_at and
# updated_at one millisecond apart, and pressing Refresh again did the same
# thing, which is what made the button look broken.
RSpec.describe Meta::TokenRefresh do
  let(:fresh) { { 'access_token' => 'LONG-LIVED' } }

  it 'uses expires_in when Graph sends one' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return(fresh.merge('expires_in' => 5_184_000))
    expect(MetaGraphApi).not_to receive(:debug_token)

    result = described_class.call('SOURCE')

    expect(result.access_token).to eq('LONG-LIVED')
    expect(result.expires_at).to be_within(5.seconds).of(60.days.from_now)
  end

  # The bug: no expires_in must not mean "expired now".
  it 'asks Graph outright when there is no expires_in, rather than reading it as zero' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return(fresh)
    allow(MetaGraphApi).to receive(:debug_token).with('LONG-LIVED')
      .and_return({ 'data' => { 'is_valid' => true, 'expires_at' => 45.days.from_now.to_i } })

    result = described_class.call('SOURCE')

    expect(result.expires_at).to be_within(5.seconds).of(45.days.from_now)
  end

  # expires_at 0 is Graph for "never". Stored as nil, which every reader
  # already treats as not expiring.
  it 'reports a token that never expires as having no expiry' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return(fresh)
    allow(MetaGraphApi).to receive(:debug_token).and_return({ 'data' => { 'is_valid' => true, 'expires_at' => 0 } })

    expect(described_class.call('SOURCE').expires_at).to be_nil
  end

  it 'keeps the new token when debug_token cannot answer' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return(fresh)
    allow(MetaGraphApi).to receive(:debug_token).and_raise(MetaGraphApi::Error.new('nope'))

    result = described_class.call('SOURCE')

    expect(result.access_token).to eq('LONG-LIVED')
    expect(result.expires_at).to be_nil
  end

  it 'keeps the token it was given when Graph returns no new one' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return({})
    allow(MetaGraphApi).to receive(:debug_token).and_return({ 'data' => { 'expires_at' => 0 } })

    expect(described_class.call('SOURCE').access_token).to eq('SOURCE')
  end
end
