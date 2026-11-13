# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::LegalPages do
  let(:digest_class) { Struct.new(:links) }
  let(:response_class) { Struct.new(:url, :body) }

  let(:policy_body) do
    paragraphs = Array.new(12) do |i|
      "<p>Section #{i}: we collect personal information you give us through forms, such as your name, " \
        'phone number and email address, and use it only to answer your inquiry about a home.</p>'
    end
    <<~HTML
      <html><body>
        <header><nav><a href="/">Home</a></nav></header>
        <main>
          <h1>Privacy Policy</h1>
          <h2>What we collect</h2>
          #{paragraphs.join}
          <p></p>
          <script>alert(1)</script>
          <form><input name="email"></form>
        </main>
        <footer>Copyright</footer>
      </body></html>
    HTML
  end

  let(:fetcher) do
    pages = {}
    double('fetcher').tap do |f|
      allow(f).to receive(:get) { |url, **| pages[url] }
      f.define_singleton_method(:pages) { pages }
    end
  end

  def digests_with(*links)
    [digest_class.new(links.map { |href, label| { href: href, label: label } })]
  end

  it 'keeps a real policy whole, without the page chrome, the title or anything executable' do
    fetcher.pages['https://dealer.com/privacy-policy'] = response_class.new('https://dealer.com/privacy-policy', policy_body)
    result = described_class.new(
      digests_with(['https://dealer.com/privacy-policy', 'Privacy Policy']),
      base_url: 'https://www.dealer.com', fetcher: fetcher
    ).call

    html = result.dig('privacy', 'html')
    expect(html).to include('<h2>What we collect</h2>', 'Section 11')
    expect(html).not_to include('<h1>', '<script', '<form', 'Copyright', '<p></p>')
    expect(result['privacy']['url']).to eq('https://dealer.com/privacy-policy')
    expect(result).not_to have_key('terms')
  end

  it "skips WordPress's unedited starter policy, so the site keeps ours" do
    wordpress = File.read(Rails.root.join('spec/fixtures/site_profiles/wordpress_privacy.html'))
    fetcher.pages['https://dealer.com/privacy-policy'] = response_class.new('https://dealer.com/privacy-policy', wordpress)
    result = described_class.new(
      digests_with(['https://dealer.com/privacy-policy', 'Privacy Policy']),
      base_url: 'https://dealer.com', fetcher: fetcher
    ).call

    expect(result).to eq({})
  end

  it 'skips a stub and never follows a link to another site' do
    fetcher.pages['https://dealer.com/terms'] = response_class.new('https://dealer.com/terms', '<main><p>Terms coming soon.</p></main>')
    result = described_class.new(
      digests_with(['https://dealer.com/terms', 'Terms'], ['https://elsewhere.com/privacy', 'Privacy']),
      base_url: 'https://dealer.com', fetcher: fetcher
    ).call

    expect(result).to eq({})
    expect(fetcher).not_to have_received(:get).with('https://elsewhere.com/privacy', anything)
  end

  it 'never reads from the archive' do
    described_class.new(
      digests_with(['https://dealer.com/privacy', 'Privacy']), base_url: 'https://dealer.com', fetcher: fetcher
    ).call

    expect(fetcher).to have_received(:get).with('https://dealer.com/privacy', allow_archive: false)
  end
end
