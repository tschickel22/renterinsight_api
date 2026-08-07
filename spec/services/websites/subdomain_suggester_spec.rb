# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::SubdomainSuggester do
  # Availability stubbed by default so these test the naming rules rather than
  # whatever happens to be in the database.
  def suggest(name, taken: ->(_c) { false })
    described_class.suggest(name, taken: taken)
  end

  describe '.suggest' do
    it 'turns a trading name into an address' do
      expect(suggest('Mobile Home Masters')).to eq('mobile-home-masters')
    end

    it 'keeps apostrophes from splitting a word' do
      expect(suggest("O'Brien Homes")).to eq('obrien-homes')
    end

    it 'spells out an ampersand rather than dropping it' do
      expect(suggest('Land & Home Co')).to eq('land-and-home-co')
    end

    it 'collapses punctuation and spacing' do
      expect(suggest('Summit Park  --  Manufactured Homes, Inc.')).to eq('summit-park-manufactured-homes-inc')
    end

    it 'refuses a name too short to be an address' do
      expect(suggest('AB')).to be_nil
      expect(suggest('')).to be_nil
      expect(suggest(nil)).to be_nil
    end

    # -2 rather than random noise: a dealer reading their own URL aloud should
    # be able to recognise and remember it.
    it 'numbers a name that is already taken' do
      taken = ->(c) { c == 'summit-park' }

      expect(suggest('Summit Park', taken: taken)).to eq('summit-park-2')
    end

    it 'keeps counting past the second collision' do
      taken = ->(c) { %w[summit-park summit-park-2 summit-park-3].include?(c) }

      expect(suggest('Summit Park', taken: taken)).to eq('summit-park-4')
    end

    it 'stays within the length limit when it adds a suffix' do
      long = 'a' * described_class::MAX_LENGTH
      result = suggest(long, taken: ->(c) { c == long })

      expect(result.length).to be <= described_class::MAX_LENGTH
      expect(result).to end_with('-2')
    end

    # "origin" is the Cloudflare for SaaS fallback origin that every dealer
    # custom domain resolves through. Handing it to a site would point that
    # dealer's address at the plumbing.
    it 'never hands out a reserved name' do
      %w[www origin connect api app mail].each do |reserved|
        expect(suggest(reserved)).not_to eq(reserved)
      end
    end
  end

  describe '.valid?' do
    it 'accepts a well-formed address' do
      expect(described_class.valid?('summit-park')).to be(true)
      expect(described_class.valid?('abc')).to be(true)
    end

    it 'rejects anything a hostname label may not contain' do
      ['Summit-Park', 'summit_park', 'summit park', 'summit.park', 'sümmit'].each do |bad|
        expect(described_class.valid?(bad)).to be(false)
      end
    end

    it 'rejects leading, trailing and doubled hyphens' do
      ['-summit', 'summit-', 'summit--park'].each do |bad|
        expect(described_class.valid?(bad)).to be(false)
      end
    end

    it 'rejects reserved names and out-of-range lengths' do
      expect(described_class.valid?('origin')).to be(false)
      expect(described_class.valid?('ab')).to be(false)
      expect(described_class.valid?('a' * 41)).to be(false)
    end
  end

  describe 'Website validation' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
    let(:location) { company.locations.create!(name: 'Showroom') }

    def site(subdomain)
      Website.new(company_id: company.id, location_id: location.id, name: 'Dealer Site',
                  slug: "s-#{SecureRandom.hex(4)}", subdomain: subdomain)
    end

    it 'refuses a reserved address with an explanation' do
      record = site('origin')

      expect(record).not_to be_valid
      expect(record.errors[:subdomain].join).to match(/reserved/i)
    end

    it 'refuses a malformed address' do
      expect(site('Not Valid')).not_to be_valid
    end

    it 'accepts a good one, and still accepts none at all' do
      expect(site('summit-park')).to be_valid
      expect(site(nil)).to be_valid
    end
  end
end
