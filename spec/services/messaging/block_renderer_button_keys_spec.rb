# frozen_string_literal: true

require 'rails_helper'

# Seeded templates write buttons as label/url; the renderer read only text/href.
RSpec.describe Messaging::BlockRenderer, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def render(block)
    described_class.new(blocks: [block], context: {}, company: company, unsubscribe_url: 'https://example.com/u/x').render
  end

  it 'renders a template button written as label and url' do
    html = render({ 'type' => 'button', 'label' => 'Browse all homes', 'url' => 'https://dealer.example/homes' })

    expect(html).to include('Browse all homes')
    expect(html).to include('href="https://dealer.example/homes"')
    expect(html).not_to include('Click here')
  end

  it 'still renders a builder button written as text and href' do
    html = render({ 'type' => 'button', 'text' => 'Book a time', 'href' => 'https://dealer.example/book' })

    expect(html).to include('Book a time')
    expect(html).to include('href="https://dealer.example/book"')
  end
end
