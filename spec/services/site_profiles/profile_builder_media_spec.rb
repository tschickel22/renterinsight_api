# frozen_string_literal: true

require 'rails_helper'

# The image-selection half of ProfileBuilder.
#
# Regression cover for the defect that put a dealer's American flag graphic
# behind the headline of every generated page. The AI call is stubbed at its
# seam so this exercises the real merge.
RSpec.describe SiteProfiles::ProfileBuilder do
  let(:company) { Company.create!(name: "Flag-#{SecureRandom.hex(4)}") }

  def digest(url, backgrounds)
    SiteProfiles::PageDigest::Digest.new(
      url: url, title: 'T', headings: [], paragraphs: [], images: [],
      background_images: backgrounds, links: [], forms: [], iframes: [],
      scripts: { external: [], inline: [] }, text_ratio: 0.5
    )
  end

  # Whatever the model returned, before the deterministic merge.
  def build(model_media:, digests:, inventory_images: [])
    builder = described_class.new(company: company)
    allow(builder).to receive(:call_claude).and_return(
      text: { 'media' => model_media }.to_json,
      model_version: 'test', input_tokens: 1, output_tokens: 1
    )
    profile, = builder.call(digests: digests, source_url: 'https://d.example',
                            inventory_images: inventory_images)
    profile['media']
  end

  let(:flag) { 'https://d.example/img/usa-flag-banner.jpg' }
  let(:home) { 'https://d.example/img/model-home-exterior.jpg' }
  let(:home2) { 'https://d.example/img/doublewide-front.jpg' }

  it 'keeps a promotional graphic out of the hero even when the model picked it' do
    media = build(
      model_media: { 'hero_images' => [flag, home] },
      digests: [digest('https://d.example/', [home])]
    )

    expect(media['hero_images']).not_to include(flag)
    expect(media['hero_images']).to include(home)
  end

  # The original defect. Each page returned photos-then-promos, and flat_map
  # across pages interleaved them, so page one's banner outranked page two's
  # photography.
  it 'does not let an earlier page\'s promo outrank a later page\'s photography' do
    media = build(
      model_media: {},
      digests: [
        digest('https://d.example/', [flag]),
        digest('https://d.example/homes', [home])
      ]
    )

    expect(media['hero_images'].first).to eq(home)
    expect(media['hero_images']).not_to include(flag)
  end

  it 'still offers the promo for the gallery' do
    media = build(
      model_media: {},
      digests: [digest('https://d.example/', [flag, home])]
    )

    expect(media['gallery']).to include(flag)
    # ...but never ahead of an actual home.
    expect(media['gallery'].index(home)).to be < media['gallery'].index(flag)
  end

  # "An empty hero_images list is fine and is handled downstream" — this is
  # that handling. Falling through to stock imagery that belongs to nobody is
  # worse than showing homes we actually hold.
  it 'falls back to stored inventory photography when nothing survives' do
    media = build(
      model_media: { 'hero_images' => [flag] },
      digests: [digest('https://d.example/', [flag])],
      inventory_images: [home2]
    )

    expect(media['hero_images']).to eq([home2])
  end

  it 'prefers the scan over stored inventory when the scan found real homes' do
    media = build(
      model_media: {},
      digests: [digest('https://d.example/', [home])],
      inventory_images: [home2]
    )

    expect(media['hero_images']).to eq([home])
  end

  it 'leaves the hero empty when there is no imagery anywhere' do
    media = build(model_media: {}, digests: [digest('https://d.example/', [flag])])

    expect(media['hero_images']).to eq([])
  end
end
