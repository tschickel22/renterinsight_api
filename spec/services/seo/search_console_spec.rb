# frozen_string_literal: true

require 'rails_helper'

# Specced against Google's documented response shape, with the network injected.
# The parsing is covered here; the live handshake is not, and cannot be until an
# OAuth client and a verified property exist.
RSpec.describe Seo::SearchConsole do
  # Trimmed from the shape Google documents for urlInspection.index:inspect.
  let(:indexed_response) do
    {
      'inspectionResult' => {
        'indexStatusResult' => {
          'verdict' => 'PASS',
          'coverageState' => 'Submitted and indexed',
          'lastCrawlTime' => '2026-08-09T14:22:01Z',
          'robotsTxtState' => 'ALLOWED'
        },
        'richResultsResult' => {
          'verdict' => 'PASS',
          'detectedItems' => [
            { 'richResultType' => 'Product snippets',
              'items' => [{ 'name' => '2026 Skyline Prairie Dune', 'issues' => [] }] },
            { 'richResultType' => 'Breadcrumbs', 'items' => [{ 'name' => 'Trail', 'issues' => [] }] }
          ]
        }
      }
    }
  end

  def stub_http(response)
    ->(_url, _body, _token) { response }
  end

  describe 'reading what Google saw' do
    subject(:result) do
      described_class.inspect_one(site_url: 'https://dealer.com/', page_url: 'https://dealer.com/homes/a',
                                  token: 'tok', http: stub_http(indexed_response))
    end

    it 'reports the page as indexed, with when it was last looked at' do
      expect(result).to be_indexed
      expect(result.coverage_state).to eq('Submitted and indexed')
      expect(result.last_crawled_at).to eq('2026-08-09T14:22:01Z')
    end

    # The question our own audit cannot answer: not "is the markup valid" but
    # "did Google see a rich result here".
    it 'names the rich results Google actually detected' do
      expect(result.rich_results).to contain_exactly('Product snippets', 'Breadcrumbs')
    end

    it 'is clean when nothing is wrong' do
      expect(result.rich_result_issues).to be_empty
      expect(result).to be_ok
    end
  end

  describe 'a page Google would not index' do
    it 'says so rather than reporting a bare failure' do
      response = { 'inspectionResult' => { 'indexStatusResult' => {
        'verdict' => 'FAIL', 'coverageState' => 'Discovered, currently not indexed'
      } } }

      result = described_class.inspect_one(site_url: 'https://dealer.com/',
                                           page_url: 'https://dealer.com/homes/a',
                                           token: 'tok', http: stub_http(response))

      expect(result).not_to be_indexed
      expect(result.coverage_state).to eq('Discovered, currently not indexed')
    end
  end

  describe 'markup Google rejected' do
    # The whole point of asking Google rather than ourselves: our rules say the
    # markup qualifies, and Google says what it did with it.
    it 'surfaces only the issues that actually cost the result' do
      response = indexed_response.deep_dup
      response['inspectionResult']['richResultsResult']['detectedItems'][0]['items'][0]['issues'] = [
        { 'issueMessage' => 'Missing field "price"', 'severity' => 'ERROR' },
        { 'issueMessage' => 'Missing field "aggregateRating"', 'severity' => 'WARNING' }
      ]

      result = described_class.inspect_one(site_url: 'https://dealer.com/',
                                           page_url: 'https://dealer.com/homes/a',
                                           token: 'tok', http: stub_http(response))

      expect(result.rich_result_issues).to eq(['Missing field "price"'])
    end
  end

  describe 'when the request does not work' do
    # Google answers 200 with an error object often enough that a status check
    # alone is not enough to know it worked.
    it 'reads an error returned inside a successful response' do
      response = { 'error' => { 'code' => 403, 'message' => 'User does not have sufficient permission' } }

      result = described_class.inspect_one(site_url: 'https://dealer.com/', page_url: 'https://dealer.com/a',
                                           token: 'tok', http: stub_http(response))

      expect(result).not_to be_ok
      expect(result.error).to match(/sufficient permission/)
    end

    it 'never raises out of a network failure' do
      exploding = ->(_url, _body, _token) { raise Errno::ECONNREFUSED }

      result = described_class.inspect_one(site_url: 'https://dealer.com/', page_url: 'https://dealer.com/a',
                                           token: 'tok', http: exploding)

      expect(result).not_to be_ok
      expect(result.url).to eq('https://dealer.com/a')
    end

    it 'says plainly when nothing is configured, rather than pretending to check' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SEARCH_CONSOLE_REFRESH_TOKEN').and_return(nil)

      results = described_class.inspect_urls(site_url: 'https://dealer.com/',
                                             page_urls: ['https://dealer.com/a'])

      expect(results.first.error).to match(/no Search Console credentials/)
    end
  end

  describe 'how much it asks for' do
    # A dealer with a thousand homes would blow through the daily quota, so a
    # caller samples rather than sweeps.
    it 'samples rather than inspecting every page it is handed' do
      urls = Array.new(40) { |i| "https://dealer.com/homes/#{i}" }

      results = described_class.inspect_urls(site_url: 'https://dealer.com/', page_urls: urls,
                                             token: 'tok', http: stub_http(indexed_response))

      expect(results.size).to eq(described_class::DEFAULT_SAMPLE)
    end
  end
end
