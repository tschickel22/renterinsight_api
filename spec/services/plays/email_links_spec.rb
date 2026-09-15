# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Play email links' do
  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:play) { Plays::NewFacebookLead.new(company: company, user: nil, answers: {}) }

  def html(text)
    play.send(:paragraphs, text)
  end

  it 'makes a web address a link, leaving sentence punctuation outside it' do
    expect(html("Watch the overview: https://www.youtube.com/watch?v=aPfnr_RFj0Q.\nThanks"))
      .to eq('<p>Watch the overview: <a href="https://www.youtube.com/watch?v=aPfnr_RFj0Q">' \
             'https://www.youtube.com/watch?v=aPfnr_RFj0Q</a>.<br>Thanks</p>')
  end

  it 'keeps a dealer\'s markup escaped and an address with a query string intact' do
    expect(html('<b>Hi</b> see https://example.com/a?b=1&c=2'))
      .to eq('<p>&lt;b&gt;Hi&lt;/b&gt; see <a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a></p>')
    expect(html('No links here, just words.')).to eq('<p>No links here, just words.</p>')
  end
end
