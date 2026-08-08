# frozen_string_literal: true

require 'rails_helper'

# Guards the shared HTTP behaviour every adapter inherits. Written after a
# production Test on the Adventure Homes source reported "0 homes discovered"
# with nothing in the logs: the host had answered with a 202 and a ~190 byte
# bot-challenge stub, which Net::HTTPSuccess matched, so the stub was handed
# back as though it were the page and parsed into zero links.
RSpec.describe Catalog::Adapters::BaseAdapter do
  let(:source) { build(:catalog_source, base_url: 'https://example-homes.com', config: {}) }
  let(:adapter) { described_class.new(source) }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl?).and_return(true)
    allow(http).to receive(:verify_mode=)
    allow(http).to receive(:cert_store=)
  end

  def respond_with(klass, code, body, headers = {})
    response = klass.new('1.1', code, 'msg')
    allow(response).to receive(:body).and_return(body)
    headers.each { |k, v| allow(response).to receive(:[]).with(k).and_return(v) }
    allow(response).to receive(:[]).and_return(nil) if headers.empty?
    allow(http).to receive(:request).and_return(response)
    response
  end

  describe '#http_get' do
    it 'returns the body on 200' do
      respond_with(Net::HTTPOK, '200', '<urlset><loc>x</loc></urlset>')
      expect(adapter.send(:http_get, 'https://example-homes.com/sitemap.xml'))
        .to include('<loc>')
    end

    # The regression: a 202 challenge stub used to come back as content.
    it 'refuses a 202 rather than passing the challenge stub off as content' do
      respond_with(Net::HTTPAccepted, '202', '<html>Access denied. Just a moment...</html>')
      expect(adapter.send(:http_get, 'https://example-homes.com/sitemap.xml')).to be_nil
    end

    it 'refuses a 204, which carries no body to parse' do
      respond_with(Net::HTTPNoContent, '204', '')
      expect(adapter.send(:http_get, 'https://example-homes.com/sitemap.xml')).to be_nil
    end

    it 'says so in the log, so a blocked source is not a silent zero' do
      respond_with(Net::HTTPAccepted, '202', 'stub')
      expect(Rails.logger).to receive(:error).with(/HTTP 202 \(non-200 success\)/)
      adapter.send(:http_get, 'https://example-homes.com/sitemap.xml')
    end

    it 'still returns nil on a 403' do
      respond_with(Net::HTTPForbidden, '403', 'blocked')
      expect(adapter.send(:http_get, 'https://example-homes.com/sitemap.xml')).to be_nil
    end
  end

  describe '#http_probe' do
    it 'reports who answered and with what, for diagnosing a block' do
      respond_with(Net::HTTPAccepted, '202', 'nope',
                   'server' => 'nginx', 'content-type' => 'text/html', 'location' => nil)

      probe = adapter.send(:http_probe, 'https://example-homes.com/sitemap.xml')
      expect(probe).to include(status: 202, bytes: 4, server: 'nginx', content_type: 'text/html')
    end
  end

  describe '#user_agent' do
    it 'defaults to the shared browser UA' do
      expect(adapter.user_agent).to eq(described_class::USER_AGENT)
    end

    it 'lets a source override it, for hosts whose WAF rejects the default' do
      source.config = { 'user_agent' => 'Custom/1.0' }
      expect(adapter.user_agent).to eq('Custom/1.0')
    end
  end
end
