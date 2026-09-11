# frozen_string_literal: true

require 'rails_helper'

# Why a scanned hero looked soft beside the client's own site.
#
# A page lays an image out at the size it needs and asks the CDN for exactly
# that: measured on thehomeplus.com, every <img> carries ?width=600 for a
# 1600x1000 original. We captured the 600px file and then stretched it across a
# full-width hero, so the demo was visibly blurrier than the site it was
# copying — 600x375 against their sharp original.
RSpec.describe SiteProfiles::PageDigest do
  def full_size(url)
    described_class.allocate.send(:full_size_image, url)
  end

  it 'asks for the original rather than the laid-out thumbnail' do
    expect(full_size('https://trove.b-cdn.net/images/abc.jpeg?width=600'))
      .to eq('https://trove.b-cdn.net/images/abc.jpeg')
  end

  it 'unwraps an image served through the Next.js optimiser' do
    url = 'https://thehomeplus.com/_next/image?url=https%3A%2F%2Ftrove.b-cdn.net%2Fimages%2Fabc.jpeg&w=640&q=75'

    expect(full_size(url)).to eq('https://trove.b-cdn.net/images/abc.jpeg')
  end

  it 'drops every spelling of a size knob' do
    expect(full_size('https://cdn.example.com/a.jpg?w=400&h=300&q=70&dpr=2'))
      .to eq('https://cdn.example.com/a.jpg')
  end

  # Crop is framing, not sizing: a floor plan cropped to the plan must stay
  # cropped, or we would "improve" it into a page scan.
  it 'keeps a crop, which is a decision rather than a size' do
    expect(full_size('https://cdn.example.com/plan.png?crop=1469,600&width=600'))
      .to eq('https://cdn.example.com/plan.png?crop=1469%2C600')
  end

  it 'leaves a query it does not recognise alone' do
    expect(full_size('https://cdn.example.com/a.jpg?v=3')).to eq('https://cdn.example.com/a.jpg?v=3')
  end

  it 'leaves a plain URL exactly as it was' do
    expect(full_size('https://cdn.example.com/a.jpg')).to eq('https://cdn.example.com/a.jpg')
  end

  # A URL we cannot parse is one we can only break.
  it 'returns anything unparseable untouched' do
    expect(full_size('::not a url::')).to eq('::not a url::')
  end

  it 'applies to images found in the markup' do
    html = '<html><body><main><img src="https://trove.b-cdn.net/images/x.jpeg?width=600" alt="home"></main></body></html>'
    digest = described_class.new(
      SiteProfiles::Fetcher::Response.new(url: 'https://dealer.com/', status: 200,
                                          body: html, content_type: 'text/html')
    ).call

    expect(digest.images.first[:src]).to eq('https://trove.b-cdn.net/images/x.jpeg')
  end

  it 'applies to CSS background images too, which is where dealers put photography' do
    html = '<html><body><main><div style="background-image:url(https://cdn.example.com/hero.jpg?width=800)">x</div></main></body></html>'
    digest = described_class.new(
      SiteProfiles::Fetcher::Response.new(url: 'https://dealer.com/', status: 200,
                                          body: html, content_type: 'text/html')
    ).call

    expect(digest.background_images).to include('https://cdn.example.com/hero.jpg')
  end
end
