# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TurnstileDomainService do
  around do |example|
    keys = %w[TURNSTILE_SITE_KEY CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN]
    original = ENV.to_h.slice(*keys)
    ENV['TURNSTILE_SITE_KEY'] = '0xSITEKEY'
    ENV['CLOUDFLARE_ACCOUNT_ID'] = 'acct1'
    ENV['CLOUDFLARE_API_TOKEN'] = 'token1'
    example.run
    keys.each { |k| original.key?(k) ? ENV[k] = original[k] : ENV.delete(k) }
  end

  let(:widget) do
    { name: 'DealerTide Lead Intake', mode: 'managed', bot_fight_mode: false, region: 'world',
      clearance_level: 'no_clearance', offlabel: false, ephemeral_id: false,
      domains: %w[dealertide.com mydealertide.com renterinsight.com] }
  end

  def response(result)
    instance_double(HTTParty::Response, success?: true, code: 200,
                                        body: { success: true, result: result }.to_json)
  end

  before { allow(described_class).to receive(:get).and_return(response(widget)) }

  # www.easyhomesource.com, 2026-10-20: the widget listed only our own domains, so the bot
  # check could not run there and every lead form submission was rejected.
  it 'adds a dealer domain without www, keeping every other setting' do
    expect(described_class).to receive(:put) do |path, opts|
      expect(path).to eq('/accounts/acct1/challenges/widgets/0xSITEKEY')
      body = JSON.parse(opts[:body], symbolize_names: true)
      expect(body[:domains]).to eq(%w[dealertide.com mydealertide.com renterinsight.com easyhomesource.com])
      expect(body.except(:domains)).to eq(widget.except(:domains))
      response(widget)
    end

    expect(described_class.new.allow!('www.easyhomesource.com')).to eq(:added)
  end

  it 'leaves the widget alone when an entry already covers the hostname' do
    expect(described_class).not_to receive(:put)

    expect(described_class.new.allow!('www.info.dealertide.com')).to eq(:already_covered)
  end

  it 'refuses rather than exceeding the plan limit' do
    allow(described_class).to receive(:get)
      .and_return(response(widget.merge(domains: (1..10).map { |i| "d#{i}.example" })))
    expect(described_class).not_to receive(:put)

    expect { described_class.new.allow!('www.new.example') }.to raise_error(described_class::Full)
  end

  # Missing from the widget means the dealer loses every lead, so a failure is never quiet.
  it 'alerts when it cannot add the domain' do
    allow(described_class).to receive(:get).and_return(
      instance_double(HTTParty::Response, success?: false, code: 403,
                                          body: { success: false, errors: [{ message: 'Authentication error' }] }.to_json)
    )
    expect(Ops::Alert).to receive(:notify!).with('turnstile:dealer.example', /dealer\.example/, /Authentication error/, every: 1.day)

    expect(described_class.allow_with_alert('www.dealer.example')).to eq(:failed)
  end

  it 'does nothing when Turnstile is not configured' do
    ENV.delete('TURNSTILE_SITE_KEY')
    expect(described_class).not_to receive(:get)

    expect(described_class.allow_with_alert('www.dealer.example')).to eq(:not_configured)
  end
end
