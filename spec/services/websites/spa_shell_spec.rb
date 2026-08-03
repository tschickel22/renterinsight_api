# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::SpaShell do
  let(:shell_html) { '<!doctype html><html><head><title>App</title></head><body>café</body></html>' }

  def stub_origin(body:, status: Net::HTTPOK)
    response = status.new('1.1', status == Net::HTTPOK ? '200' : '500', 'OK')
    allow(response).to receive(:body).and_return(body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:get).and_return(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  around do |example|
    original = ENV['WEBSITE_SPA_ORIGIN']
    ENV['WEBSITE_SPA_ORIGIN'] = 'https://spa.example.com'
    Rails.cache.clear
    example.run
    original ? ENV['WEBSITE_SPA_ORIGIN'] = original : ENV.delete('WEBSITE_SPA_ORIGIN')
    Rails.cache.clear
  end

  # Net::HTTP hands back ASCII-8BIT unless the response declares a charset it recognises.
  # Every dealer page then died with Encoding::CompatibilityError the moment the binary body
  # met the UTF-8 literals used to inject head tags, surfacing as a bare 500 with nothing in
  # the message pointing at encoding.
  it 'returns UTF-8 even when the origin responds in binary' do
    stub_origin(body: shell_html.dup.force_encoding(Encoding::ASCII_8BIT))

    result = described_class.fetch

    expect(result.encoding).to eq(Encoding::UTF_8)
    expect(result).to be_valid_encoding
  end

  it 'can be concatenated with UTF-8 without raising' do
    stub_origin(body: shell_html.dup.force_encoding(Encoding::ASCII_8BIT))

    expect { "#{described_class.fetch}<meta property=\"og:title\" content=\"Café\">" }
      .not_to raise_error
  end

  # A stray byte in the shell should not take every dealer site down.
  it 'scrubs invalid bytes rather than raising' do
    stub_origin(body: "<html>\xC3\x28 broken</html>".dup.force_encoding(Encoding::ASCII_8BIT))

    expect { described_class.fetch }.not_to raise_error
    expect(described_class.fetch).to be_valid_encoding
  end

  it 'rewrites relative asset paths to the origin' do
    stub_origin(body: '<script src="/assets/index-abc.js"></script>')

    expect(described_class.fetch).to include('src="https://spa.example.com/assets/index-abc.js"')
  end

  it 'raises ShellUnavailable when the origin errors' do
    stub_origin(body: 'boom', status: Net::HTTPInternalServerError)

    expect { described_class.fetch }.to raise_error(described_class::ShellUnavailable)
  end
end
