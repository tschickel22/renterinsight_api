# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::AiSearchChecks do
  let(:files) { {} }
  let(:fetcher) do
    double('fetcher').tap do |f|
      allow(f).to receive(:get) do |url|
        path = URI(url).path
        body = files[path]
        body && Struct.new(:url, :status, :body, :content_type).new(url, 200, body, 'text/plain')
      end
    end
  end

  def report(pages, js_only_pages: 0)
    SiteProfiles::SeoAudit.new(source_url: 'https://dealer.test', pages_html: pages, fetcher: fetcher,
                               js_only_pages: js_only_pages).call
  end

  def check(pages, key, **opts) = report(pages, **opts)['checks'].detect { |c| c['key'] == key }

  let(:words) { (['word'] * 200).join(' ') }
  let(:plain) { { 'https://dealer.test/' => "<html><body><h1>Dealer</h1><p>#{words}</p></body></html>" } }

  describe 'AI assistant access' do
    it 'fails when robots.txt blocks AI crawlers' do
      files['/robots.txt'] = "User-agent: GPTBot\nDisallow: /\n\nUser-agent: ClaudeBot\nDisallow: /\n\nUser-agent: *\nAllow: /\n"
      c = check(plain, 'ai_crawlers')
      expect(c['status']).to eq('fail')
      expect(c['detail']).to include('GPTBot', 'ClaudeBot')
    end

    it 'fails when everything is disallowed' do
      files['/robots.txt'] = "User-agent: *\nDisallow: /\n"
      expect(check(plain, 'ai_crawlers')['status']).to eq('fail')
    end

    it 'passes when a named allow overrides a wildcard block' do
      files['/robots.txt'] = "User-agent: *\nDisallow: /\n\n" + SiteProfiles::AiSearchChecks::AI_BOTS.map { |b| "User-agent: #{b}\nAllow: /\n" }.join("\n")
      expect(check(plain, 'ai_crawlers')['status']).to eq('pass')
    end
  end

  describe 'readable without JavaScript' do
    it 'fails an empty app shell' do
      shell = { 'https://dealer.test/' => '<html><body><div id="root"></div><script src="/app.js"></script></body></html>' }
      expect(check(shell, 'ai_readable')['status']).to eq('fail')
    end

    it 'fails when the scan needed a browser for some pages' do
      expect(check(plain, 'ai_readable', js_only_pages: 3)['headline']).to start_with('3 pages')
    end

    it 'passes pages whose text is in the HTML' do
      expect(check(plain, 'ai_readable')['status']).to eq('pass')
    end
  end

  describe 'FAQs' do
    it 'warns about FAQs without markup' do
      page = { 'https://dealer.test/faq' => "<html><body><h2>FAQ</h2><h3>Do you finance?</h3><p>Yes.</p><p>#{words}</p></body></html>" }
      c = check(page, 'faq')
      expect(c['status']).to eq('warn')
      expect(c['headline']).to include('no FAQ markup')
    end

    it 'passes FAQPage markup' do
      ld = { '@context' => 'https://schema.org', '@type' => 'FAQPage', 'mainEntity' => [] }.to_json
      page = { 'https://dealer.test/' => %(<html><head><script type="application/ld+json">#{ld}</script></head><body><p>#{words}</p></body></html>) }
      expect(check(page, 'faq')['status']).to eq('pass')
    end
  end

  describe 'business details' do
    it 'fails template placeholders' do
      page = { 'https://dealer.test/contact' => "<html><body><p>Call (555) 987-6543 at Your Dealership Name. #{words}</p></body></html>" }
      expect(check(page, 'nap')['status']).to eq('fail')
    end
  end

  describe 'freshness' do
    it 'passes recently dated content' do
      page = { 'https://dealer.test/blog/post/x' => %(<html><body><time datetime="#{3.days.ago.to_date.iso8601}">x</time><p>#{words}</p></body></html>) }
      expect(check(page, 'freshness')['status']).to eq('pass')
    end

    it 'warns when nothing is dated' do
      expect(check(plain, 'freshness')['status']).to eq('warn')
    end
  end

  it 'tags the AI checks and scores them on their own' do
    r = report(plain)
    expect(r['checks'].select { |c| c['category'] == 'ai' }.map { |c| c['key'] }).to include('ai_crawlers', 'faq', 'llms_txt')
    expect(r['ai_score']).to be_a(Integer)
  end

  describe 'llms.txt' do
    it 'passes when published' do
      files['/llms.txt'] = "# Dealer\n\n> Homes"
      expect(check(plain, 'llms_txt')['status']).to eq('pass')
    end
  end
end
