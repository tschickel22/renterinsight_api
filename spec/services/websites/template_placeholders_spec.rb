# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::TemplatePlaceholders do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '(303) 555-0142', email: 'sales@summitpark.example',
                    address_line1: '800 Colfax Ave', city: 'Denver', state: 'CO', zip_code: '80202')
  end
  subject(:scrubber) { described_class.new(company: company) }

  it 'swaps the template identity for the dealer one' do
    html = '<p><strong>Phone:</strong> (555) 123-4567</p><p><strong>Email:</strong> info@yourdealership.com</p>' \
           '<p><strong>Address:</strong> 123 Dealer Drive<br>Your City, ST 12345</p>'

    expect(scrubber.scrub(html)).to eq(
      '<p><strong>Phone:</strong> (303) 555-0142</p><p><strong>Email:</strong> sales@summitpark.example</p>' \
      '<p><strong>Address:</strong> 800 Colfax Ave<br>Denver, CO 80202</p>'
    )
  end

  it 'walks nested blocks, links and titles' do
    data = {
      'seo' => { 'title' => 'Homes | Your Dealership Name' },
      'blocks' => [{ 'content' => { 'address' => '456 Coastal Blvd, Your City, ST 12345',
                                    'links' => [{ 'text' => 'Call', 'url' => 'tel:5551234567' }] } }]
    }

    out = scrubber.scrub(data)
    expect(out['seo']['title']).to eq('Homes | Summit Park Homes')
    expect(out['blocks'][0]['content']['address']).to eq('800 Colfax Ave, Denver, CO 80202')
    expect(out['blocks'][0]['content']['links'][0]['url']).to eq('tel:3035550142')
  end

  it 'removes what the company does not have instead of leaving it fake' do
    bare = described_class.new(company: Company.create!(name: 'Bare Co'))
    expect(bare.scrub('Call (555) 987-6543 or hello@yourdealership.com')).to eq('Call  or ')
    expect(bare.scrub('123 Dealer Drive, Your City, ST 12345')).to eq('')
  end

  it 'prefers the site location when it has a street' do
    location = company.locations.create!(name: 'Lot 2', address_line1: '9 Pine Rd', city: 'Boulder', state: 'CO',
                                         zip_code: '80301', phone: '720-555-0100')
    out = described_class.new(company: company, location: location).scrub('100 Modern Way, Your City, ST 12345 (555) 321-0987')
    expect(out).to eq('9 Pine Rd, Boulder, CO 80301 720-555-0100')
  end

  it 'leaves real text alone' do
    expect(scrubber.scrub('Open 9 to 5. Call 303-555-0142.')).to eq('Open 9 to 5. Call 303-555-0142.')
  end
end
