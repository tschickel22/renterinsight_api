# frozen_string_literal: true

require 'rails_helper'

# A logo drawn as an inline <svg> has no URL, so the <img> search walks past it
# and the extractor falls through to og:image — which on a dealer site is a
# photograph of a home, not the mark.
#
# The counter-case matters just as much and is the common one: measured on
# thehomeplus.com, every <svg> in the header is a 14-28px chevron or social
# glyph and the real logo is an <img>. Taking "an svg in the header" as the mark
# would have put a dropdown arrow in the demo, so an inline SVG is only accepted
# on positive evidence.
RSpec.describe SiteProfiles::BrandExtractor do
  def extract(html)
    described_class.new([{ url: 'https://dealer.com/', html: html }]).call
  end

  # A wordmark as a site actually ships one: named, and header height.
  let(:mark) do
    '<svg class="site-logo" viewBox="0 0 120 40" width="120" height="40">' \
      '<path d="M0 0h120v40H0z"/><text>Home +</text></svg>'
  end

  it 'takes an inline header svg as the logo' do
    logo = extract("<html><body><header>#{mark}</header></body></html>")['logo_url']

    expect(logo).to start_with('data:image/svg+xml;base64,')
    expect(Base64.decode64(logo.split(',').last)).to include('viewBox="0 0 120 40"')
  end

  it 'gives it a namespace so an <img> will actually draw it' do
    logo = extract("<html><body><nav>#{mark}</nav></body></html>")['logo_url']

    expect(Base64.decode64(logo.split(',').last)).to include('xmlns="http://www.w3.org/2000/svg"')
  end

  # og:image on a dealer site is a home, not a mark.
  it 'prefers the inline mark over og:image' do
    html = <<~HTML
      <html><head><meta property="og:image" content="https://cdn.example.com/hero-home.png"></head>
      <body><header>#{mark}</header></body></html>
    HTML

    expect(extract(html)['logo_url']).to start_with('data:image/svg+xml')
  end

  # A real <img> logo is still the better answer: it is the file the dealer
  # actually publishes, and it rehosts onto our S3.
  it 'still prefers a real logo image when the site has one' do
    html = <<~HTML
      <html><body><header>
        <img src="/assets/sunshine-logo.png" alt="Sunshine Homes">
        #{mark}
      </header></body></html>
    HTML

    expect(extract(html)['logo_url']).to eq('https://dealer.com/assets/sunshine-logo.png')
  end

  # The shape thehomeplus.com actually serves.
  it 'ignores a nav chevron that happens to sit in the header' do
    chevron = '<svg stroke="currentColor" fill="none" viewBox="0 0 15 15" height="1em" ' \
              'width="1em" class="ml-0.5 transition-transform"><path d="M7.5 9.9L10.8 6.8"/></svg>'
    html = "<html><body><header><a href=\"/homes\">Floor Plans #{chevron}</a></header></body></html>"

    expect(extract(html)['logo_url']).to be_nil
  end

  it 'takes an unnamed mark when it is what the home link is made of' do
    bare = '<svg viewBox="0 0 140 44" width="140" height="44"><path d="M0 0h140v44H0z"/></svg>'
    html = "<html><body><header><a href=\"/\">#{bare}</a></header></body></html>"

    expect(extract(html)['logo_url']).to start_with('data:image/svg+xml')
  end

  it 'ignores the hamburger and the search icon' do
    html = <<~HTML
      <html><body><header>
        <button class="menu-toggle"><svg viewBox="0 0 10 10"><path d="M0 0h10"/></svg></button>
        <button aria-label="Search"><svg viewBox="0 0 12 12"><circle cx="5" cy="5" r="4"/></svg></button>
      </header></body></html>
    HTML

    expect(extract(html)['logo_url']).to be_nil
  end

  it 'leaves an oversized inline illustration alone' do
    huge = "<svg viewBox=\"0 0 999 999\"><path d=\"#{'M0 0h1' * 20_000}\"/></svg>"

    expect(extract("<html><body><header>#{huge}</header></body></html>")['logo_url']).to be_nil
  end
end
