# frozen_string_literal: true

require 'rails_helper'

# Server watch (backlog E79): tells the platform owner, by email and text,
# when a server crashed, is near its memory limit, or is failing, at most once
# per kind of alert however many server processes notice it.
RSpec.describe Ops::Watch do
  around do |ex|
    old = ENV.to_h.slice('OPS_ALERT_EMAIL', 'OPS_ALERT_PHONE', 'RENDER_GIT_COMMIT', 'RENDER_SERVICE_NAME', 'RENDER_INSTANCE_ID')
    ENV.update('OPS_ALERT_EMAIL' => 'ops@example.com', 'OPS_ALERT_PHONE' => '+13035550100', 'RENDER_SERVICE_NAME' => 'api-prod')
    ex.run
  ensure
    %w[OPS_ALERT_EMAIL OPS_ALERT_PHONE RENDER_GIT_COMMIT RENDER_SERVICE_NAME RENDER_INSTANCE_ID].each { |k| ENV.delete(k) }
    ENV.update(old)
  end

  let(:texts) { [] }

  before do
    allow(TwilioSmsService).to receive(:send_via_master) { |to:, body:| texts << [to, body]; { success: true } }
    ActionMailer::Base.deliveries.clear
  end

  it 'says nothing when a release or scaling starts new servers, and reports a server that starts again' do
    ENV['RENDER_INSTANCE_ID'] = 'web-aaa'
    described_class.booted!
    ENV['RENDER_INSTANCE_ID'] = 'web-bbb'
    described_class.booted!
    expect(texts).to be_empty

    described_class.booted!
    expect(texts.size).to eq(1)
    expect(texts.first.first).to eq('+13035550100')
    expect(texts.first.last).to start_with('Production: a web server crashed and restarted')
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['ops@example.com']])
  end

  it 'sends one alert of a kind however many processes notice, then again after the quiet period' do
    expect(Ops::Alert.notify!('memory', 'high', 'x')).to be(true)
    expect(Ops::Alert.notify!('memory', 'high', 'x')).to be(false)
    expect(Ops::Alert.notify!('errors', 'many', 'x')).to be(true)
    travel_to(31.minutes.from_now) { expect(Ops::Alert.notify!('memory', 'high', 'x')).to be(true) }
    expect(texts.size).to eq(3)
  end

  it 'sends nothing where no one is set to hear it' do
    ENV.delete('OPS_ALERT_EMAIL')
    ENV.delete('OPS_ALERT_PHONE')
    expect(Ops::Alert.notify!('memory', 'high', 'x')).to be(false)
    expect(texts).to be_empty
  end

  it 'warns before memory runs out' do
    allow(described_class).to receive(:memory).and_return(used: 1800.megabytes, max: 2048.megabytes)
    described_class.check_memory!
    expect(texts.last.last).to include('api-prod is at 88% of its memory')

    allow(described_class).to receive(:memory).and_return(used: 1000.megabytes, max: 2048.megabytes)
    texts.clear
    travel_to(1.hour.from_now) { described_class.check_memory! }
    expect(texts).to be_empty
  end

  it 'keeps server errors, reports a spike, and stamps the jobs heartbeat' do
    boom = RuntimeError.new('boom')
    30.times { described_class.error!(exception_object: boom, method: 'GET', path: '/api/v1/leads') }
    described_class.error!(status: 404, method: 'GET', path: '/nope')
    expect(ServerError.count).to eq(30)

    described_class.check!
    expect(texts.last.last).to include('30 server errors').and include('30 x RuntimeError on /api/v1/leads')
    expect(OpsMark.at('heartbeat:jobs')).to be_within(5.seconds).of(Time.current)
  end
end

RSpec.describe 'GET /up/jobs', type: :request do
  it 'answers 200 while jobs check in, 503 when they stop' do
    get '/up/jobs'
    expect(response).to have_http_status(:service_unavailable)

    OpsMark.stamp!('heartbeat:jobs')
    get '/up/jobs'
    expect(response).to have_http_status(:ok)

    OpsMark.stamp!('heartbeat:jobs', at: 20.minutes.ago)
    get '/up/jobs'
    expect(response).to have_http_status(:service_unavailable)
  end
end
