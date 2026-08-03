# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::RequestHost do
  def request_for(host:, tenant_host: nil, secret: nil)
    env = { 'HTTP_HOST' => host }
    env['HTTP_X_TENANT_HOST'] = tenant_host if tenant_host
    env['HTTP_X_TENANT_PROXY_SECRET'] = secret if secret
    ActionDispatch::Request.new(Rack::MockRequest.env_for('http://example.com', env))
  end

  around do |example|
    original = ENV['TENANT_PROXY_SECRET']
    example.run
    original ? ENV['TENANT_PROXY_SECRET'] = original : ENV.delete('TENANT_PROXY_SECRET')
  end

  context 'with no proxy secret configured' do
    before { ENV.delete('TENANT_PROXY_SECRET') }

    it 'uses the connection host' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com')

      expect(described_class.for(request)).to eq('renterinsight-api-prod.onrender.com')
    end

    # Deploying the Worker before setting the secret must change nothing rather than
    # trusting a header nobody is verifying.
    it 'ignores the tenant host header entirely' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com',
                            tenant_host: 'www.dealer.com', secret: 'anything')

      expect(described_class.for(request)).to eq('renterinsight-api-prod.onrender.com')
    end
  end

  context 'with a proxy secret configured' do
    before { ENV['TENANT_PROXY_SECRET'] = 'sekret' }

    it 'uses the forwarded host when the secret matches' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com',
                            tenant_host: 'www.dealer.com', secret: 'sekret')

      expect(described_class.for(request)).to eq('www.dealer.com')
    end

    # Without this, anyone could call the Render hostname directly claiming to be any
    # dealer's domain and be served that dealer's site under it.
    it 'ignores a forwarded host with the wrong secret' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com',
                            tenant_host: 'www.dealer.com', secret: 'wrong')

      expect(described_class.for(request)).to eq('renterinsight-api-prod.onrender.com')
    end

    it 'ignores a forwarded host with no secret at all' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com',
                            tenant_host: 'www.dealer.com')

      expect(described_class.for(request)).to eq('renterinsight-api-prod.onrender.com')
    end

    it 'falls back to the connection host when only the secret is present' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com', secret: 'sekret')

      expect(described_class.for(request)).to eq('renterinsight-api-prod.onrender.com')
    end

    it 'normalises case and strips a port' do
      request = request_for(host: 'renterinsight-api-prod.onrender.com',
                            tenant_host: 'WWW.Dealer.com:443', secret: 'sekret')

      expect(described_class.for(request)).to eq('www.dealer.com')
    end
  end
end
