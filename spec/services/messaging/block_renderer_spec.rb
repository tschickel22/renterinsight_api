# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::BlockRenderer do
  let(:company) { Company.create!(name: 'Acme MH') }
  let(:context) { { 'first_name' => 'Sam', 'company' => { 'name' => 'Acme MH' } } }

  it 'renders text blocks with merge tags resolved' do
    blocks = [{ 'type' => 'text', 'html' => '<p>Hi {{first_name}}, see {{company.name}}</p>' }]
    out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u').render
    expect(out).to include('Hi Sam, see Acme MH')
  end

  it 'renders button blocks with escaped attributes' do
    blocks = [{ 'type' => 'button', 'text' => 'Click me', 'href' => 'https://x.test' }]
    out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u').render
    expect(out).to include('href="https://x.test"')
    expect(out).to include('Click me')
  end

  it 'renders dividers and skips invalid types' do
    blocks = [{ 'type' => 'divider' }, { 'type' => 'unknown_x' }]
    out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u').render
    expect(out).to include('<hr')
  end

  it 'renders inventory cards when units provided' do
    blocks = [{ 'type' => 'inventory' }]
    units = [{ id: 1, year: 2024, make: 'Skyline', model: 'Aspen', sale_price: 89000, bedrooms: 3, bathrooms: 2, image_url: 'https://i.test/1.jpg', url: 'https://x.test/v/1' }]
    out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', inventory_units: units).render
    expect(out).to include('2024 Skyline Aspen')
    expect(out).to include('$89,000')
  end

  it 'renders unsubscribe footer with company name and link' do
    blocks = [{ 'type' => 'footer_unsubscribe' }]
    out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u/abc').render
    expect(out).to include('Acme MH')
    expect(out).to include('Unsubscribe')
    expect(out).to include('https://u/abc')
  end

  describe 'branded_header block' do
    let(:branding) { { logo_url: 'https://cdn.test/logo.png', primary_color: '#00aa55', name: 'Evangeline Home Center', phone: '(337) 555-0100', address: '123 Main St, Ville Platte, LA 70586' } }

    it 'renders logo, phone, address, and brand-color accent bar' do
      blocks = [{ 'type' => 'branded_header' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', branding: branding).render
      expect(out).to include('https://cdn.test/logo.png')
      expect(out).to include('(337) 555-0100')
      expect(out).to include('123 Main St, Ville Platte, LA 70586')
      expect(out).to include('background:#00aa55') # accent bar
    end

    it 'falls back to a text name when no logo is set' do
      blocks = [{ 'type' => 'branded_header' }]
      no_logo = branding.merge(logo_url: nil)
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', branding: no_logo).render
      expect(out).to include('Evangeline Home Center')
      expect(out).not_to include('<img')
    end

    it 'silently renders nothing when branding data is entirely absent' do
      blocks = [{ 'type' => 'branded_header' }, { 'type' => 'text', 'html' => '<p>Body</p>' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', branding: {}).render
      expect(out).to include('Body')
      expect(out).not_to include('background:#1f2937')
    end
  end

  describe 'sender_cta block' do
    let(:branding) { { primary_color: '#00aa55' } }
    let(:contact) { { name: 'Jacob Andries', title: 'Sales Manager', email: 'jacob@evh.com', phone: '(337) 555-0100', address: '123 Main St', booking_url: 'https://calendly.com/jacob', location_name: 'Evangeline Home Center' } }

    it 'renders the full contact card with tour link' do
      blocks = [{ 'type' => 'sender_cta', 'cta_text' => 'Schedule a tour' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', branding: branding, contact: contact).render
      expect(out).to include('Jacob Andries')
      expect(out).to include('Sales Manager')
      expect(out).to include('Evangeline Home Center')
      expect(out).to include('mailto:jacob@evh.com')
      expect(out).to include('(337) 555-0100')
      expect(out).to include('https://calendly.com/jacob')
      expect(out).to include('Schedule a tour')
      expect(out).to include('color:#00aa55') # brand-color link
    end

    it 'omits the booking link when the rep has no booking_url' do
      blocks = [{ 'type' => 'sender_cta' }]
      no_booking = contact.merge(booking_url: nil)
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', branding: branding, contact: no_booking).render
      expect(out).to include('Jacob Andries')
      expect(out).not_to include('Schedule a tour')
    end

    it 'silently renders nothing when contact data is entirely absent' do
      blocks = [{ 'type' => 'sender_cta' }, { 'type' => 'text', 'html' => '<p>Body</p>' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', branding: branding, contact: {}).render
      expect(out).to include('Body')
      expect(out).not_to include('Jacob Andries')
    end
  end

  describe 'inventory layout variants' do
    let(:units) do
      [
        { id: 1, year: 2026, make: 'Tru Homes', model: 'SPRUCE',    sale_price: 89900, bedrooms: 3, bathrooms: 2, image_url: 'https://i.test/1.jpg', url: 'https://x.test/v/1' },
        { id: 2, year: 2025, make: 'Champion',  model: 'CHATEAU',   sale_price: 72500, bedrooms: 3, bathrooms: 2, image_url: 'https://i.test/2.jpg', url: 'https://x.test/v/2' },
        { id: 3, year: 2024, make: 'Clayton',   model: 'PRIDE',     sale_price: 54900, bedrooms: 2, bathrooms: 2, image_url: 'https://i.test/3.jpg', url: 'https://x.test/v/3' }
      ]
    end

    it 'defaults to hero-plus-rows: first card full-width, rest as compact rows' do
      blocks = [{ 'type' => 'inventory' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', inventory_units: units).render
      # Hero card: centered content, no fixed-width thumbnail
      expect(out).to include('2026 Tru Homes SPRUCE')
      expect(out).to include('text-align:center')
      # Row cards: 160-wide thumbnail
      expect(out).to include('width="160"')
      expect(out.scan('width="160"').length).to eq(2) # only rows 2 and 3
    end

    it 'renders all rows when layout=all_rows' do
      blocks = [{ 'type' => 'inventory', 'layout' => 'all_rows' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', inventory_units: units).render
      expect(out.scan('width="160"').length).to eq(3)
      expect(out).not_to include('text-align:center')
    end

    it 'renders all heroes when layout=all_hero' do
      blocks = [{ 'type' => 'inventory', 'layout' => 'all_hero' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', inventory_units: units).render
      expect(out).not_to include('width="160"')
      expect(out.scan('text-align:center').length).to be >= 3
    end

    it 'uses brand primary color on CTA buttons when branding is provided' do
      blocks = [{ 'type' => 'inventory' }]
      branding = { primary_color: '#00aa55' }
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', inventory_units: units, branding: branding).render
      expect(out).to include('background:#00aa55')
    end

    it 'falls back to a hero card when a row unit has no image' do
      no_image = units.dup
      no_image[1] = no_image[1].merge(image_url: nil)
      blocks = [{ 'type' => 'inventory', 'layout' => 'all_rows' }]
      out = described_class.new(blocks: blocks, context: context, company: company, unsubscribe_url: 'https://u', inventory_units: no_image).render
      # The image-less unit should render as a hero (centered), not a broken row
      expect(out).to include('2025 Champion CHATEAU')
      expect(out.scan('text-align:center').length).to be >= 1
    end
  end
end
