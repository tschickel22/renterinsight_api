# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::PixelInjector do
  it 'injects tracking pixel before </body>' do
    html = '<html><body><p>Hi</p></body></html>'
    out = described_class.inject(html, communication_id: 42, base_url: 'https://app.test')
    expect(out).to include('/webhooks/email/42/pixel.gif')
    expect(out.index('<img')).to be < out.index('</body>')
  end

  it 'falls back to append when no </body> tag is present' do
    html = '<p>Naked content</p>'
    out = described_class.inject(html, communication_id: 7, base_url: 'https://app.test')
    expect(out).to start_with('<p>Naked content</p>')
    expect(out).to include('/webhooks/email/7/pixel.gif')
  end

  it 'returns html unchanged when communication_id missing' do
    html = '<p>x</p>'
    expect(described_class.inject(html, communication_id: nil, base_url: 'https://x')).to eq(html)
  end

  it 'returns blank when input is blank' do
    expect(described_class.inject('', communication_id: 1, base_url: 'https://x')).to eq('')
  end
end
