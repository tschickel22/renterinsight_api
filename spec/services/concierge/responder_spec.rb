# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Concierge::Responder do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '555-0100',
                    address_line1: '100 Lot Road', city: 'Denver', state: 'CO')
  end
  let(:location) { company.locations.create!(name: 'Showroom') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published', published_at: Time.current)
  end

  def home(price:, beds: 3, baths: 2, sqft: 1200, make: 'Champion')
    company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: make, model: 'Shoal Creek',
                             status: 'available', sale_price: price, bedrooms: beds,
                             bathrooms: baths, square_feet: sqft)
  end

  def ask(text, history: [])
    described_class.new(website: website, message: text, history: history).call
  end

  # The guard on the whole design. If a model call happens for these, the bill
  # tracks traffic instead of tracking genuinely open questions.
  describe 'questions that must never reach the model' do
    before { allow_any_instance_of(described_class).to receive(:call_claude).and_raise('model was called') }

    it 'answers where the dealer is' do
      expect(ask('where are you located?').text).to include('100 Lot Road')
    end

    it 'answers the phone number, and offers to dial it' do
      result = ask('can I call someone?')

      expect(result.text).to include('555-0100')
      expect(result.actions.first[:url]).to eq('tel:5550100')
    end

    it 'answers delivery without inventing a schedule' do
      expect(ask('do you deliver and set up?').source).to eq('rules')
    end

    it 'takes a booking request straight to an action' do
      expect(ask('can I book a tour?').actions).to be_present
    end

    it 'greets without spending anything' do
      expect(ask('hi').source).to eq('rules')
    end

    # Financing is the one where a wrong answer creates a promise the dealer has
    # to honour, so it is answered from a fixed script and handed off.
    it 'never quotes a rate or an approval' do
      text = ask('what interest rate can I get?').text

      expect(text).not_to match(/\d+(\.\d+)?\s*%/)
      expect(text).to match(/team|talk/i)
    end
  end

  describe 'inventory questions' do
    before do
      allow_any_instance_of(described_class).to receive(:call_claude).and_raise('model was called')
      home(price: 70_000)
      home(price: 120_000)
    end

    # The failure that would cost a dealer most is a chat inventing a home, and
    # a query cannot.
    it 'answers from the database rather than the model' do
      result = ask('do you have a 3 bedroom under 80k?')

      expect(result.source).to eq('inventory')
      expect(result.listings.size).to eq(1)
      expect(result.listings.first[:price]).to eq(70_000)
    end

    it 'links each home to its own page' do
      expect(ask('show me homes under 80k').listings.first[:path]).to match(%r{\A/homes/})
    end

    it 'reads over as the opposite of under' do
      expect(ask('anything over 100k?').listings.first[:price]).to eq(120_000)
    end

    it 'offers to follow up rather than dead-ending when nothing matches' do
      result = ask('do you have anything under 10k?')

      expect(result.listings).to be_empty
      expect(result.actions.first[:type]).to eq('form')
    end

    it 'never offers a home the site would not show' do
      company.vehicles.update_all(status: 'sold')

      expect(ask('show me what you have').listings).to be_empty
    end
  end

  describe 'genuinely open questions' do
    it 'escalates, and only then' do
      allow_any_instance_of(described_class).to receive(:call_claude)
        .and_return({ text: 'We can talk you through the permit process.', model_version: 'x',
                      input_tokens: 10, output_tokens: 5 })

      result = ask('what does the county need for a permit on my land?')

      expect(result.source).to eq('model')
      expect(result.text).to include('permit')
      expect(result.usage[:input_tokens]).to eq(10)
    end

    # A visitor must never see a stack trace, and a handoff is what a busy
    # salesperson would say anyway.
    it 'hands off rather than failing when the model is unreachable' do
      allow_any_instance_of(described_class).to receive(:call_claude).and_raise('boom')

      result = ask('what does the county need for a permit?')

      expect(result.source).to eq('fallback')
      expect(result.text).to include('Summit Park Homes')
      expect(result.actions).to be_present
    end
  end

  describe 'the model prompt' do
    it 'carries this dealer facts and forbids inventing others' do
      home(price: 70_000, make: 'Skyline')
      prompt = described_class.new(website: website, message: 'x').send(:system_prompt)

      expect(prompt).to include('Summit Park Homes', '100 Lot Road', 'Skyline')
      expect(prompt).to match(/Never invent/i)
      expect(prompt).to match(/Do not use dashes/i)
    end
  end

  describe 'booking' do
    it 'prefers the rep own link over the dealership' do
      rep = User.new(booking_url: 'calendly.com/rep')
      allow(rep).to receive(:booking_url).and_return('calendly.com/rep')
      resolved = Websites::BookingUrl.resolve(company: company, location: location, user: rep)

      expect(resolved).to eq('https://calendly.com/rep')
    end

    it 'falls back to a form when nothing is configured' do
      expect(Websites::BookingUrl.resolve(company: company, location: location)).to be_nil
      expect(ask('book me in').actions.first[:type]).to eq('form')
    end

    # LocationSettingsResolver reads the Location scope with one key while the
    # UI writes the other, so a booking URL saved there would silently vanish.
    it 'reads a location booking url under either key spelling' do
      Setting.set('Location', location.id, 'operational_settings', { 'booking_url' => 'acuity.com/lot' })

      expect(Websites::BookingUrl.resolve(company: company, location: location))
        .to eq('https://acuity.com/lot')
    end
  end
end
