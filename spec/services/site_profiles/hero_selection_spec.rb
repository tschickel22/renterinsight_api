# frozen_string_literal: true

require 'rails_helper'

# What goes behind the headline.
#
# A demo of thehomeplus.com came out with an architectural drawing as its hero:
# grey line-work, room labels, dimensions. Every image on that site is a CDN
# hash — trove.b-cdn.net/images/zlrsybbg32d.png — and after our own asset import
# they are hashes again, so no rule that reads a filename could ever have told a
# drawing from a photograph. The alt text can: measured on that page,
# "Ironclad 3276-21 floor plan home features" sits beside
# "Ironclad 3276-21 hero, elevation, and exterior".
RSpec.describe SiteProfiles::PageDigest do
  def digest_for(images)
    body = images.map { |i| "<img src=\"#{i[:src]}\" alt=\"#{i[:alt]}\">" }.join
    described_class.new(
      SiteProfiles::Fetcher::Response.new(url: 'https://dealer.com/', status: 200,
                                          content_type: 'text/html',
                                          body: "<html><body><main>#{body}</main></body></html>")
    ).call
  end

  # The real pairing, URLs and all.
  let(:trove_page) do
    [
      { src: 'https://trove.b-cdn.net/images/zlrsybbg32d.png', alt: 'Ironclad 3276-21 floor plan home features' },
      { src: 'https://trove.b-cdn.net/images/0vhvclz0piwd.jpeg', alt: 'Ironclad 3276-21 hero, elevation, and exterior' }
    ]
  end

  it 'never offers a floor plan as a hero' do
    heroes = digest_for(trove_page).candidate_hero_images

    expect(heroes).to eq(['https://trove.b-cdn.net/images/0vhvclz0piwd.jpeg'])
  end

  it 'keeps the floor plan for the gallery rather than discarding it' do
    expect(digest_for(trove_page).demoted_images)
      .to include('https://trove.b-cdn.net/images/zlrsybbg32d.png')
  end

  it 'puts an exterior ahead of an unlabelled photograph' do
    images = [
      { src: 'https://cdn.example.com/a.jpg', alt: 'Carousel image 1' },
      { src: 'https://cdn.example.com/b.jpg', alt: 'King 32764b hero, elevation, and exterior' }
    ]

    expect(digest_for(images).candidate_hero_images.first).to eq('https://cdn.example.com/b.jpg')
  end

  it 'keeps page order among images with nothing to choose between them' do
    images = [
      { src: 'https://cdn.example.com/1.jpg', alt: 'Carousel image 1' },
      { src: 'https://cdn.example.com/2.jpg', alt: 'Carousel image 2' }
    ]

    expect(digest_for(images).candidate_hero_images)
      .to eq(%w[https://cdn.example.com/1.jpg https://cdn.example.com/2.jpg])
  end

  # The trap in reading alt text on a dealer site: half the lot is "for sale",
  # and the promotional filter matches \bsale\b. That filter stays on the URL.
  it 'does not mistake a home for sale for a promotional banner' do
    images = [{ src: 'https://cdn.example.com/home.jpg', alt: '3376 Corky Ln, Newton NC — for sale' }]

    expect(digest_for(images).candidate_hero_images).to eq(['https://cdn.example.com/home.jpg'])
  end

  it 'still demotes a promotional graphic by its filename' do
    images = [{ src: 'https://cdn.example.com/spring-sale-banner.jpg', alt: 'Spring event' }]

    expect(digest_for(images).candidate_hero_images).to be_empty
  end

  it 'catches a floor plan named in the URL when there is no alt at all' do
    images = [{ src: 'https://cdn.example.com/the-ironclad-floor-plan.png', alt: '' }]

    expect(digest_for(images).candidate_hero_images).to be_empty
  end
end
