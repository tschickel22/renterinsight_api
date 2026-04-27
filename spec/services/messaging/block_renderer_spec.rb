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
end
