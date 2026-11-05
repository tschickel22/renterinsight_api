# frozen_string_literal: true

require 'rails_helper'
require 'cloudflare_client_ip'

# request.remote_ip was Cloudflare's edge server, so login and e-sign records held no visitor's address.
RSpec.describe CloudflareClientIp do
  def remote_ip_for(headers)
    seen = nil
    app = ->(env) { seen = ActionDispatch::Request.new(env).remote_ip; [200, {}, []] }
    described_class.new(app).call(Rack::MockRequest.env_for('/', { 'REMOTE_ADDR' => '172.68.34.118' }.merge(headers)))
    seen
  end

  it 'uses the address Cloudflare reports' do
    expect(remote_ip_for('HTTP_CF_CONNECTING_IP' => '203.0.113.9')).to eq('203.0.113.9')
    expect(remote_ip_for('HTTP_CF_CONNECTING_IP' => '2001:db8::1')).to eq('2001:db8::1')
  end

  it 'ignores nonsense, an empty header and a Worker making the request' do
    ['not-an-ip', '', CloudflareClientIp::WORKER_ADDRESS].each do |value|
      expect(remote_ip_for('HTTP_CF_CONNECTING_IP' => value)).to eq('172.68.34.118')
    end
  end

  it 'is in the middleware stack, so every controller gets it' do
    expect(Rails.application.middleware.map(&:name)).to include('CloudflareClientIp')
  end
end
