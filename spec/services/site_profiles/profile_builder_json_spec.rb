# frozen_string_literal: true

require 'rails_helper'

# A scan is minutes of crawling, rendering and reading before the model is
# called at all. Measured on a live scan of thehomeplus.com: three and a half
# minutes of work thrown away by a single unescaped quote inside a business
# name, with no retry and nothing kept.
RSpec.describe SiteProfiles::ProfileBuilder do
  let(:builder) { described_class.new(company: nil, user: nil) }

  describe 'parsing what the model returned' do
    def parse(text)
      builder.send(:parse_json, text)
    end

    it 'reads a plain object' do
      expect(parse('{"brand":{"name":"Sunshine Homes"}}')).to eq('brand' => { 'name' => 'Sunshine Homes' })
    end

    it 'reads one wrapped in a code fence' do
      expect(parse("```json\n{\"brand\":{\"name\":\"Sunshine\"}}\n```")).to have_key('brand')
    end

    # Prose either side of a valid object needs no second call.
    it 'salvages an object buried in commentary' do
      text = "Here is the profile you asked for:\n{\"brand\":{\"name\":\"Sunshine\"}}\nHope that helps!"

      expect(parse(text)).to eq('brand' => { 'name' => 'Sunshine' })
    end

    it 'gives up on something that is not JSON at all' do
      expect { parse('I could not read that site.') }
        .to raise_error(described_class::GenerationError, /invalid JSON/)
    end

    # The real failure: a quote inside a value, which no salvage can repair.
    it 'gives up on a broken string rather than guessing at the author intent' do
      expect { parse('{"brand":{"name":"Home+ Design Studio "The Homes Plus""}}') }
        .to raise_error(described_class::GenerationError)
    end
  end

  # bestbuymh.com, 2026-11-12: a large site ran past the token ceiling twice
  # and the JSON ended mid-string. The retry has to ask for a shorter answer,
  # not repeat the escaping advice that cannot help.
  describe 'retrying a reply that was cut off' do
    let(:truncated) { { text: '{"brand":{"name":"Best Buy', stop_reason: 'max_tokens' } }
    let(:complete) { { text: '{"brand":{"name":"Best Buy Homes"}}', stop_reason: 'end_turn' } }

    it 'asks for a shorter answer, and keeps the second one' do
      prompts = []
      allow(builder).to receive(:call_claude) do |**kw|
        prompts << kw[:system_prompt]
        prompts.size == 1 ? truncated : complete
      end
      allow(builder).to receive(:log_usage)

      profile, = builder.call(digests: [], source_url: 'https://bestbuymh.com/')

      expect(profile.dig('brand', 'name')).to eq('Best Buy Homes')
      expect(prompts.last).to include('cut off')
      expect(prompts.last).not_to include('Escape every double quote')
    end

    it 'still gives the escaping advice when the reply simply was not JSON' do
      prompts = []
      allow(builder).to receive(:call_claude) do |**kw|
        prompts << kw[:system_prompt]
        prompts.size == 1 ? { text: 'not json', stop_reason: 'end_turn' } : complete
      end
      allow(builder).to receive(:log_usage)

      builder.call(digests: [], source_url: 'https://bestbuymh.com/')

      expect(prompts.last).to include('Escape every double quote')
    end
  end
end
