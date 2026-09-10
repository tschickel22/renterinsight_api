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
end
