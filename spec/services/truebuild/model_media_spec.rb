# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::ModelMedia do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }

  def variant(series, name, number, champion_id: nil)
    plan = CatalogPlan.create!(manufacturer: mfr, series: series, name: name, slug: "#{name}-#{number}".parameterize)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: number,
                               external_ids: champion_id ? { 'champion_model_id' => champion_id } : {})
  end

  let(:client) do
    Class.new do
      def initialize(navision_id:); end

      def fetch_all
        [
          { 'id' => 'c-1', 'name' => 'Aspire Winston', 'seriesName' => 'Aspire Multi-Section', 'slug' => 'aspire-winston',
            'factoryBrand' => 'Dutch Housing Topeka', 'images' => [{ 'path' => 'https://s7d9.scene7.com/is/image/championhomes/Aspire 3272H32186 Kitchen 1' }] },
          { 'id' => 'c-2', 'name' => 'Prime Barkley 043', 'seriesName' => 'Prime', 'slug' => 'prime-barkley-043', 'images' => [] },
          { 'id' => 'c-3', 'name' => 'Genesis Belvidere', 'seriesName' => 'Genesis', 'slug' => 'x',
            'images' => [{ 'path' => 'https://s7d9.scene7.com/is/image/championhomes/Aspire 2856H32392 Exterior' }] }
        ]
      end

      def fetch_pdp_media(slug)
        { gallery: ["https://s7d9.scene7.com/is/image/championhomes/#{slug}-living-room-1"], elevations: [],
          floor_plans: ["https://s7d9.scene7.com/is/image/championhomes/#{slug}-floorplan"], matterport_url: 'https://my.matterport.com/show/?m=abc' }
      end
    end
  end

  it 'links by model number when the series agrees, by name for plans without one, and tags rooms' do
    winston = variant('Aspire', 'Winston', '3272H32186')
    barkley = variant('Prime Of Indiana', 'Barkley Reverse Aisle', '1676H32P03')
    belvidere = variant('Aspire', 'Belvidere', '2856H32392')

    expect(described_class.refresh!(mfr, client_class: client)).to eq(2)

    media = winston.reload.media
    expect(media['photos'].map { |p| p['room'] }).to eq(%w[living kitchen])
    expect(media).to include('slug' => 'aspire-winston', 'matterport_url' => 'https://my.matterport.com/show/?m=abc')
    expect(winston.external_ids['champion_model_id']).to eq('c-1')
    expect(barkley.reload.media['slug']).to eq('prime-barkley-043')
    expect(belvidere.reload.media).to eq({}) # a Genesis home's photo named an Aspire number: not trusted
  end
end
