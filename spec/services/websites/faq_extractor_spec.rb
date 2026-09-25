# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::FaqExtractor do
  it 'reads the questions and answers under the FAQ heading' do
    html = <<~HTML
      <p>Intro.</p>
      <h2>What changed?</h2><p>Not a FAQ.</p>
      <h2>Frequently asked questions</h2>
      <h3>Do you finance?</h3><p>Yes.</p><p>Several lenders.</p>
      <h3>Is there a warranty?</h3><p>One year.</p>
      <h3>No answer?</h3>
      <h2>Next steps</h2><p>Call us.</p>
    HTML

    expect(described_class.from_html(html)).to eq([
      ['Do you finance?', 'Yes. Several lenders.'],
      ['Is there a warranty?', 'One year.']
    ])
  end

  it 'finds nothing without a FAQ section' do
    expect(described_class.from_html('<h2>Why?</h2><h3>Q</h3><p>A</p>')).to eq([])
    expect(described_class.from_html(nil)).to eq([])
  end
end
