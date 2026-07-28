# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboundEmail::ReplyBodyCleaner do
  it 'splits off a blockquote-quoted original' do
    html = '<p>Sounds great, book me in!</p><blockquote>On Mon, Tom wrote: original...</blockquote>'
    res = described_class.split(html)
    expect(res.reply).to eq('<p>Sounds great, book me in!</p>')
    expect(res.quoted).to include('blockquote')
  end

  it 'splits at an Outlook "From: ... Sent:" header block' do
    html = "Yes let's talk.\n\nFrom: Tom Schickel\nSent: Monday\nTo: test lead\nSubject: Re:"
    res = described_class.split(html)
    expect(res.reply).to eq("Yes let's talk.")
    expect(res.quoted).to include('From:')
  end

  it 'splits at an "On ... wrote:" marker' do
    html = "I'd love a tour this weekend.\nOn Mon, Jul 27, 2026 at 8:55 AM Tom wrote:\nquoted body"
    res = described_class.split(html)
    expect(res.reply).to eq("I'd love a tour this weekend.")
    expect(res.quoted).to start_with('On Mon')
  end

  it 'returns the whole body as reply when no quote marker is present' do
    html = '<p>Just a short reply with no quoted history.</p>'
    res = described_class.split(html)
    expect(res.reply).to eq(html)
    expect(res.quoted).to be_nil
  end

  it 'keeps the whole body when the quote marker is at the very start (reply-only)' do
    html = '<blockquote>entirely quoted, no new text</blockquote>'
    res = described_class.split(html)
    expect(res.reply).to eq(html)
    expect(res.quoted).to be_nil
  end

  it 'handles blank input safely' do
    res = described_class.split('')
    expect(res.reply).to eq('')
    expect(res.quoted).to be_nil
  end
end

# Regression: a one-word reply arrived in the CRM as the entire quoted thread
# plus Gmail's "Be Careful With This Message" banner, flattened into a single
# paragraph — the reply itself was the first word and easy to miss entirely.
RSpec.describe InboundEmail::ReplyBodyCleaner, 'Gmail-style quote headers' do
  it 'cuts at a From/Date/Subject header block' do
    body = "Thanks!\n\nFrom: Tom Admin\nDate: Tuesday, July 28, 2026 at 3:57 PM\n" \
           "To: t+hm75g@renterinsight.com\nSubject: Welcome to Main Location\n" \
           'Be Careful With This Message ... Hi Henry, Welcome to Main Location!'

    result = described_class.split(body)

    expect(result.reply).to eq('Thanks!')
    expect(result.quoted).to include('Be Careful With This Message')
  end

  it 'keeps the security banner out of the reply' do
    body = "Sounds good.\n\nFrom: Sales\nDate: Monday\nSubject: Quote\n" \
           'Newly Registered Domain The message was sent from a domain that...'

    expect(described_class.split(body).reply).to eq('Sounds good.')
  end

  # Conservative by design: never hide content when unsure.
  it 'leaves an ordinary reply mentioning dates alone' do
    body = 'Can we move the date? Subject to your availability.'

    expect(described_class.split(body).reply).to eq(body)
  end
end
