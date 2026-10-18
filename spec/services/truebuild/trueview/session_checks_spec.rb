# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::SessionChecks do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:run) do
    TruebuildFactoryRun.create!(manufacturer_id: mfr.id, budget_usd: 5, variant_ids: [], status: 'running', mode: 'batch',
                                progress: { 'checks' => 'session' })
  end
  let(:layer) { { bytes: 'png', mime: 'image/png', coverage: 0.3 } }

  before { allow(Truebuild::Trueview).to receive(:store) { |_, _, _, suffix:| "https://b/#{suffix}.png" } }

  def row(value = 'Clay', usage = {})
    TruebuildRender.create!(source_url: 'https://p/kitchen.jpg', room: 'kitchen', purpose: 'layer', status: 'running',
                            selection: [{ 'surface' => 'Siding', 'value' => value }], selection_key: "k#{SecureRandom.hex(2)}",
                            model_key: 'nb2-lite', provider: 'gemini', model: 'lite', prompt: 'p',
                            usage: { 'factory_run_id' => run.id, 'batch' => true, 'batch_drawn' => 'https://b/d.png' }.merge(usage))
  end

  it 'holds a drawing for the session instead of the API, and lists it with the rubric the API is given' do
    expect(Truebuild::Trueview::LayerCheck).not_to receive(:judge)
    r = row
    described_class.await!(r, kind: 'batch', layer: layer)
    expect(r.reload).to have_attributes(status: 'running', layer_url: 'https://b/batch-layer.png')
    expect(r.usage).not_to have_key('batch_drawn')
    item = described_class.pending(run).first
    expect(item).to include(id: r.id, kind: 'batch', surface: 'Siding', value: 'Clay', layer_url: 'https://b/batch-layer.png')
    expect(item[:rubric]).to include('Is all of the visible Siding in the new finish', 'Passes at 4')
    expect(Truebuild::Trueview::FactoryRun.progress(run)).to include(phase: 'waiting_on_claude_code', awaiting_checks: 1, checks: 'session')
  end

  it 'passes, draws again, or holds back as the API verdict would' do
    passed = row.tap { |r| described_class.await!(r, kind: 'batch', layer: layer) }
    again = row.tap { |r| described_class.await!(r, kind: 'batch', layer: layer) }
    held = row('Clay', 'tries' => 2).tap { |r| described_class.await!(r, kind: 'batch', layer: layer) }
    described_class.apply!(passed, 'score' => 5)
    described_class.apply!(again, 'score' => 2, 'note' => 'Wrong color.')
    described_class.apply!(held, 'score' => 2, 'note' => 'Wrong color.')
    expect(passed.reload).to have_attributes(status: 'done')
    expect(passed.usage['check']).to include('ok' => true, 'by' => 'session')
    expect(again.reload).to have_attributes(status: 'queued')
    expect(again.usage['notes']).to eq(['Wrong color.'])
    expect(held.reload).to have_attributes(status: 'rejected', error: 'Hidden: Wrong color.')
  end

  it 'draws a plain color whose tint failed, in the next batch' do
    r = row.tap { |x| described_class.await!(x, kind: 'tint', layer: layer, image: { bytes: 'i', mime: 'image/png' }, usage: { 'tint_hex' => '#aabbcc' }) }
    described_class.apply!(r, 'score' => 3, 'note' => 'Too blue.')
    expect(r.reload).to have_attributes(status: 'queued', image_url: nil)
    expect(r.usage).to include('tint_failed' => true, 'tint_note' => 'Too blue.')
  end
end
