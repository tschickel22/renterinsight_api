# frozen_string_literal: true

require 'rails_helper'

# The order a page is tried in, and why it matters.
#
# thehomeplus.com — a competitor build, and we expect many more like it —
# answers HTTP 429 with the checkpoint page in this fixture to anything without
# a JavaScript engine. Chrome clears it in about two seconds and finds 368 words
# and 28 internal links. So: fetch, then render, and only then the archive,
# which for that domain holds nothing but a parked redirect.
RSpec.describe SiteProfiles::Fetcher do
  let(:challenge) { Rails.root.join('spec/fixtures/site_profiles/vercel_checkpoint.html').read }
  let(:dealer_page) do
    <<~HTML
      <html><head><title>Home + Design Studio</title></head><body>
        <header><img src="https://cdn.example.com/mark.png" alt="Home + Design Studio logo"></header>
        <h1>Manufactured homes in Hickory</h1>
        <p>#{'Delivery, foundation work and financing handled in house for buyers across the county. ' * 8}</p>
      </body></html>
    HTML
  end

  around do |example|
    example.run
    %w[SITE_SCAN_RENDERER SITE_SCAN_RENDER_TOKEN].each { |k| ENV.delete(k) }
  end

  # Real Net::HTTP objects rather than doubles: Fetcher#get branches with
  # `case response when Net::HTTPSuccess`, and case/when asks the CLASS
  # (Module#===), which walks straight past a stubbed is_a?.
  def stub_wire(status:, body:, content_type: 'text/html')
    klass = status == 200 ? Net::HTTPOK : Net::HTTPTooManyRequests
    response = klass.new('1.1', status.to_s, '')
    response['content-type'] = content_type
    allow(response).to receive(:body).and_return(body)
    allow_any_instance_of(described_class).to receive(:perform).and_return(response)
  end

  context 'when a bot wall answers and rendering is configured' do
    before do
      ENV['SITE_SCAN_RENDERER'] = 'browserless'
      ENV['SITE_SCAN_RENDER_TOKEN'] = 'key_1'
      stub_wire(status: 429, body: challenge)
    end

    it 'returns the rendered page' do
      allow_any_instance_of(SiteProfiles::Renderer).to receive(:call).and_return(dealer_page)

      response = described_class.new.get('https://thehomeplus.com/')

      expect(response.body).to include('Manufactured homes in Hickory')
      expect(response).to be_rendered
      expect(response).not_to be_from_archive
    end

    it 'never reaches for the archive when the browser got there first' do
      allow_any_instance_of(SiteProfiles::Renderer).to receive(:call).and_return(dealer_page)
      expect(SiteProfiles::ArchiveFallback).not_to receive(:new)

      described_class.new.get('https://thehomeplus.com/')
    end

    it 'falls back to the archive when rendering fails' do
      allow_any_instance_of(SiteProfiles::Renderer).to receive(:call).and_return(nil)
      archived = described_class::Response.new(url: 'https://thehomeplus.com/', status: 200,
                                               body: '<html><body>old copy</body></html>',
                                               content_type: 'text/html', from_archive: true)
      allow_any_instance_of(SiteProfiles::ArchiveFallback).to receive(:call).and_return(archived)

      expect(described_class.new.get('https://thehomeplus.com/')).to be_from_archive
    end
  end

  # The other half of the same problem: HTTP 200, valid HTML, and nothing in it.
  context 'when the site answers 200 with an empty shell' do
    before do
      ENV['SITE_SCAN_RENDERER'] = 'browserless'
      ENV['SITE_SCAN_RENDER_TOKEN'] = 'key_1'
      stub_wire(status: 200, body: '<html><body><div id="root"></div><script src="/app.js"></script></body></html>')
    end

    it 'renders it rather than scanning the shell' do
      allow_any_instance_of(SiteProfiles::Renderer).to receive(:call).and_return(dealer_page)

      expect(described_class.new.get('https://dealer.com/').body).to include('Manufactured homes')
    end
  end

  context 'when rendering is not configured' do
    before { ENV.delete('SITE_SCAN_RENDERER') }

    it 'behaves exactly as it did before, archive and all' do
      stub_wire(status: 429, body: challenge)
      archived = described_class::Response.new(url: 'https://thehomeplus.com/', status: 200,
                                               body: '<html><body>old copy</body></html>',
                                               content_type: 'text/html', from_archive: true)
      allow_any_instance_of(SiteProfiles::ArchiveFallback).to receive(:call).and_return(archived)

      expect(described_class.new.get('https://thehomeplus.com/')).to be_from_archive
    end

    it 'leaves a page that reads fine completely alone' do
      stub_wire(status: 200, body: dealer_page)
      expect(SiteProfiles::ArchiveFallback).not_to receive(:new)

      response = described_class.new.get('https://dealer.com/')

      expect(response).not_to be_rendered
      expect(response.body).to include('Manufactured homes in Hickory')
    end
  end
end
