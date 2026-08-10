# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Seo::RichResultRules do
  def issues(node)
    described_class.issues_for([node])
  end

  def properties(node, severity: nil)
    list = issues(node)
    list = list.select { |i| i.severity == severity } if severity
    list.map(&:property)
  end

  describe 'a listing' do
    let(:complete) do
      {
        '@type' => 'Product', 'name' => '2026 Skyline Prairie Dune',
        'image' => ['https://cdn.test/a.jpg'],
        'brand' => { '@type' => 'Brand', 'name' => 'Skyline' },
        'offers' => { '@type' => 'Offer', 'price' => 89_900, 'priceCurrency' => 'USD',
                      'availability' => 'https://schema.org/InStock' }
      }
    end

    it 'passes when it carries everything a product result needs' do
      expect(issues(complete)).to be_empty
    end

    # The exact case measured on a live site: our audit said the markup was
    # present, Google said the page was ineligible.
    it 'fails a product with no offer, which is what present-only checking missed' do
      bare = complete.except('offers')

      expect(properties(bare, severity: :required)).to eq(['offers'])
    end

    # Saying it four times over is noise, and it misattributes: the currency we
    # never got to emit is not a separate failure of ours.
    it 'reports the missing offer once rather than every property beneath it' do
      bare = complete.except('offers')

      expect(properties(bare)).to eq(['offers'])
    end

    it 'fails an offer with no price, since a price is the point' do
      priceless = complete.merge('offers' => { '@type' => 'Offer', 'priceCurrency' => 'USD' })

      expect(properties(priceless, severity: :required)).to eq(['offers.price'])
    end

    it 'reads a price out of an array of offers' do
      many = complete.merge('offers' => [{ '@type' => 'Offer', 'price' => 1, 'priceCurrency' => 'USD',
                                           'availability' => 'https://schema.org/InStock' }])

      expect(issues(many)).to be_empty
    end

    # A missing price is the dealer not having entered one. A missing currency is
    # us not emitting it. Conflating them fills an internal report with noise
    # nobody can action.
    it 'separates what the dealer did not enter from what we failed to emit' do
      priceless = complete.merge('offers' => { '@type' => 'Offer', 'availability' => 'x' })
      sources = issues(priceless).to_h { |i| [i.property, i.source] }

      expect(sources['offers.price']).to eq(:data)
      expect(sources['offers.priceCurrency']).to eq(:markup)
    end
  end

  describe 'a dealership' do
    let(:complete) do
      {
        '@type' => 'LocalBusiness', 'name' => 'Summit Park Homes',
        'address' => { '@type' => 'PostalAddress', 'streetAddress' => '100 Lot Road',
                       'postalCode' => '80231' },
        'telephone' => '555-0100', 'image' => 'https://cdn.test/lot.jpg',
        'priceRange' => '$80,000 to $150,000',
        'openingHoursSpecification' => [{ '@type' => 'OpeningHoursSpecification' }]
      }
    end

    it 'passes a fully described dealership' do
      expect(issues(complete)).to be_empty
    end

    it 'blocks on a missing postal code, which is what local search matches on' do
      no_zip = complete.merge('address' => { '@type' => 'PostalAddress', 'streetAddress' => '100 Lot Road' })

      expect(properties(no_zip, severity: :required)).to eq(['address.postalCode'])
    end

    # The business type follows the dealer's industry, so checking the literal
    # string would skip every dealer we mark up correctly.
    it 'recognises the industry-specific types as a local business' do
      expect(issues(complete.merge('@type' => 'AutoDealer'))).to be_empty
      expect(properties(complete.except('priceRange').merge('@type' => 'SelfStorage'))).to eq(['priceRange'])
    end

    it 'treats hours and price range as detail rather than as blocking' do
      sparse = complete.except('priceRange', 'openingHoursSpecification')

      expect(properties(sparse, severity: :required)).to be_empty
      expect(properties(sparse, severity: :recommended)).to contain_exactly('priceRange',
                                                                            'openingHoursSpecification')
    end
  end

  describe 'reading a page' do
    it 'finds nodes nested under @graph, the way most sites nest them' do
      parsed = { '@context' => 'https://schema.org',
                 '@graph' => [{ '@type' => 'WebSite' }, { '@type' => 'BreadcrumbList' }] }

      expect(described_class.nodes_from(parsed).map { |n| n['@type'] })
        .to eq(%w[WebSite BreadcrumbList])
    end

    it 'reads a bare node and a top-level array too' do
      expect(described_class.nodes_from({ '@type' => 'Product' }).size).to eq(1)
      expect(described_class.nodes_from([{ '@type' => 'Product' }, { '@type' => 'WebSite' }]).size).to eq(2)
    end

    it 'says nothing about types it has no rules for' do
      expect(issues('@type' => 'WebSite', 'name' => 'x')).to be_empty
    end

    it 'ignores anything that is not a node' do
      expect(described_class.issues_for(['nonsense', nil, 42])).to be_empty
    end
  end
end
