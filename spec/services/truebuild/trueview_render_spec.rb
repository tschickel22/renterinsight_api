# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'TrueView rendering' do
  let(:photo) { (Vips::Image.black(300, 200, bands: 3) + [150, 140, 130]).cast(:uchar) }
  let(:render) do
    TruebuildRender.create!(source_url: 'https://x/kitchen.jpg', selection: [{ 'surface' => 'Cabinets', 'value' => 'Destin White' }],
                            selection_key: 'k', model_key: 'nb2-lite', provider: 'gemini', model: 'gemini-3.1-flash-lite-image',
                            purpose: 'layer', prompt: 'p')
  end

  def png(image) = image.cast(:uchar).pngsave_buffer

  before do
    allow(Truebuild::Trueview).to receive(:fetch_source) { |url| { bytes: url.include?('mask') ? @mask_png : photo.jpegsave_buffer, mime: 'image/jpeg' } }
    allow(Truebuild::Trueview).to receive(:store) { |_r, _b, _m, **o| "https://b/#{o[:suffix] || 'full'}" }
    allow(Truebuild::Trueview).to receive(:store_bytes) { |_b, _m, key| "https://b/#{key}" }
  end

  describe 'surface outlines' do
    let(:painted) { photo.draw_rect([255, 0, 255], 0, 0, 150, 100, fill: true).cast(:uchar) }
    let(:verdict) { { 'present' => true, 'fit' => 4 } }

    before do
      # The presence question, then the outline score.
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |tool:, **|
        input = case tool[:name]
                when 'judge_presence' then { 'present' => verdict['present'] }
                when 'judge_layer' then { 'score' => 5 }
                else verdict
                end
        { input: input, input_tokens: 2000, output_tokens: 50 }
      end
    end

    def paints(image)
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |spec, _src, prompt, **|
        if prompt.include?('pure magenta')
          expect(spec[:model]).to eq('gemini-3.1-flash-lite-image')
          { bytes: png(image), mime: 'image/png', model: 'lite', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
        else
          { bytes: png((photo + 60).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 10, 'output_tokens' => 1300 } }
        end
      end
    end

    it 'outlines a surface by having the model paint it magenta, once per photo' do
      paints(painted)
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets')
      expect(mask).to have_attributes(status: 'done', surface: 'cabinets', version: Truebuild::Trueview::Surfaces::VERSION)
      expect(mask.usage['attempts']).to eq([{ 'present' => true, 'fit' => 4 }])
      expect(mask.coverage.to_f).to be_within(0.01).of(0.25)
      expect(mask.usage['cost_usd']).to eq(0.0436) # the painting, plus two questions at 2,000 in and 50 out, Sonnet rates
      expect(Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Kitchen cabinets')).to eq(mask)
    end

    it 'drops an outline Claude judges wrong, so the surface gets no layer rather than a wrong one' do
      paints(painted)
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call)
        .and_return(input: { 'present' => false, 'fit' => 1, 'note' => 'The house has no shutters; this is window glass.' },
                    input_tokens: 2000, output_tokens: 50)
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Shutters')
      expect(mask).to have_attributes(status: 'done', coverage: 0, error: 'The house has no shutters; this is window glass.')
      expect(mask.present?).to be(false)
    end

    it "paints a rejected outline again with Claude's note, and keeps the second if it passes" do
      prompts = []
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |_spec, _src, prompt, **|
        prompts << prompt
        { bytes: png(painted), mime: 'image/png', model: 'lite', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
      end
      verdicts = [{ 'present' => true, 'fit' => 2, 'note' => 'It included the microwave.' }, { 'present' => true, 'fit' => 5 }]
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |tool:, **|
        { input: tool[:name] == 'judge_presence' ? { 'present' => true } : verdicts.shift, input_tokens: 2000, output_tokens: 50 }
      end
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Backsplash')
      expect(prompts.last).to include('A previous attempt was wrong: It included the microwave.')
      expect(mask.coverage.to_f).to be > 0
      expect(mask.usage['attempts'].map { |a| a['fit'] }).to eq([2, 5])
    end

    it 'keeps an accepted outline across a version bump when its description has not changed' do
      old = TruebuildSurfaceMask.create!(source_url: 'https://x/k.jpg', surface: 'cabinets', version: 1, mask_url: 'https://b/m.png',
                                         coverage: 0.2, usage: { 'digest' => Truebuild::Trueview::Surfaces.digest('cabinets') })
      expect(Truebuild::Trueview::Providers::Gemini).not_to receive(:edit)
      allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: photo.jpegsave_buffer, mime: 'image/jpeg')
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets')
      expect(mask).to have_attributes(version: Truebuild::Trueview::Surfaces::VERSION, mask_url: 'https://b/m.png', coverage: 0.2)
      expect(mask.usage['carried_from']).to eq(old.id)
    end

    it 'asks about presence on the untouched photo alone, and paints nothing in when the answer is no' do
      paints(painted)
      calls = []
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |tool:, content:, **|
        calls << [tool[:name], content.count { |c| c[:type] == 'image' }]
        { input: { 'present' => false, 'note' => 'No shutters on this house.' }, input_tokens: 1500, output_tokens: 20 }
      end
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Shutters')
      expect(calls).to eq([['judge_presence', 1]])
      expect(mask).to have_attributes(coverage: 0, error: 'No shutters on this house.')
    end

    it 'gives an edge two outlines share to the surface that outranks the other, whichever came first' do
      countertop = png((Vips::Image.black(300, 200) + 0).draw_rect(255, 0, 0, 75, 100, fill: true))
      TruebuildSurfaceMask.create!(source_url: 'https://x/k.jpg', surface: 'countertop', version: Truebuild::Trueview::Surfaces::VERSION, mask_url: 'https://b/masks/top.png', coverage: 0.125)
      allow(Truebuild::Trueview).to receive(:fetch_source) do |url|
        url.include?('masks/') ? { bytes: countertop, mime: 'image/png' } : { bytes: photo.jpegsave_buffer, mime: 'image/jpeg' }
      end
      paints(painted) # the left quarter painted: half of it is the countertop
      cabinets = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets')
      expect(cabinets.coverage.to_f).to be_within(0.01).of(0.125)
      # The countertop outranks the cabinets, so it would keep the edge had it come second.
      expect(Truebuild::Trueview::Surfaces.outranks?('countertop', 'cabinets')).to be(true)
      expect(Truebuild::Trueview::Surfaces.claimed_above('https://x/k.jpg', 'countertop', 300, 200)).to be_nil
    end

    it 'rejects an outline that spills onto a neighbor, or an accent wall over more than one wall' do
      fit = ->(key, verdict) { Truebuild::Trueview::Surfaces.strict_fit(key, verdict) }
      expect(fit.call('cabinets', 'fit' => 5)).to eq(5)
      expect(fit.call('countertop', 'fit' => 4, 'spills_onto' => 'cabinets')).to eq(3)
      expect(fit.call('accent wall', 'fit' => 4, 'spills_onto' => 'tub or shower surround')).to eq(3)
      # The hood is the appliances', which outrank cabinets: the cut keeps it theirs.
      expect(fit.call('cabinets', 'fit' => 4, 'spills_onto' => 'appliances')).to eq(4)
      expect(fit.call('cabinets', 'fit' => 4, 'spills_onto' => 'none')).to eq(4)
      # Marked down only for a slight or harmless spill: kept.
      expect(fit.call('shingles', 'fit' => 3, 'spills_onto' => 'trim, door or window frame', 'spill_size' => 'slight', 'misses' => 'none')).to eq(4)
      expect(fit.call('accent wall', 'fit' => 3, 'spills_onto' => 'backsplash', 'spill_size' => 'clear', 'misses' => 'none', 'walls' => 1)).to eq(4)
      # Something visible left out turns it down, however clean the edges.
      expect(fit.call('cabinets', 'fit' => 4, 'spills_onto' => 'none', 'misses' => 'the cabinet above the microwave')).to eq(3)
      # A clear spill onto something lower still turns it down.
      expect(fit.call('countertop', 'fit' => 4, 'spills_onto' => 'cabinets', 'spill_size' => 'clear')).to eq(3)
      expect(fit.call('accent wall', 'fit' => 4, 'walls' => 3)).to eq(2)
      expect(fit.call('accent wall', 'fit' => 5, 'walls' => 1)).to eq(5)
    end

    it 'outlines again, told why, a surface whose outline Claude turned down, a few times' do
      turned_down = TruebuildSurfaceMask.create!(source_url: 'https://x/k.jpg', surface: 'cabinets', version: Truebuild::Trueview::Surfaces::VERSION,
                                                 status: 'done', coverage: 0, mask_url: 'https://b/m.png', error: 'It took the counter edge.',
                                                 usage: { 'attempts' => [{ 'present' => true, 'fit' => 3 }] })
      expect(Truebuild::Trueview::Surfaces.retry_due?(turned_down)).to be(false) # too soon
      turned_down.update_columns(updated_at: 1.hour.ago)
      expect(Truebuild::Trueview::Surfaces.retry_due?(turned_down)).to be(true)
      expect(Truebuild::Trueview::Surfaces).to receive(:find!)
        .with('https://x/k.jpg', 'bytes', 'cabinets', correction: 'It took the counter edge.', tries: 1).and_return(:fresh)
      expect(Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', 'bytes', 'Cabinets')).to eq(:fresh)

      last_try = TruebuildSurfaceMask.create!(source_url: 'https://x/k2.jpg', surface: 'cabinets', version: Truebuild::Trueview::Surfaces::VERSION,
                                              status: 'done', coverage: 0, mask_url: 'https://b/m.png', updated_at: 1.hour.ago,
                                              usage: { 'attempts' => [{ 'present' => true, 'fit' => 3 }], 'tries' => 2 })
      expect(Truebuild::Trueview::Surfaces.retry_due?(last_try)).to be(false)
    end

    it 'lets one job outline a surface again while the others skip it' do
      due = TruebuildSurfaceMask.create!(source_url: 'https://x/k.jpg', surface: 'cabinets', version: Truebuild::Trueview::Surfaces::VERSION,
                                         status: 'done', coverage: 0, mask_url: 'https://b/m.png', updated_at: 1.hour.ago,
                                         usage: { 'attempts' => [{ 'present' => true, 'fit' => 3 }] })
      stale = TruebuildSurfaceMask.find(due.id)
      expect(Truebuild::Trueview::Surfaces.claim(due)).to be(true)
      expect(Truebuild::Trueview::Surfaces.claim(stale)).to be(false)
    end

    it 'keeps a thin surface that covers little of the photo' do
      posts = TruebuildSurfaceMask.new(surface: 'corner posts', status: 'done', mask_url: 'https://b/m.png', coverage: 0.0009)
      wall = TruebuildSurfaceMask.new(surface: 'accent wall', status: 'done', mask_url: 'https://b/m.png', coverage: 0.0009)
      expect(posts.present?).to be(true)
      expect(wall.present?).to be(false)
    end

    it 'never cuts a layer, grown edge included, onto a surface that outranks it' do
      outline = (Vips::Image.black(300, 200) + 0).draw_rect(255, 0, 0, 150, 200, fill: true).cast(:uchar)
      blocked = (Vips::Image.black(300, 200) + 0).draw_rect(255, 150, 0, 150, 200, fill: true).cast(:uchar)
      drawn = png((photo + 60).cast(:uchar))
      free = Truebuild::Trueview::Layer.build(photo.jpegsave_buffer, drawn, mask: outline)
      held = Truebuild::Trueview::Layer.build(photo.jpegsave_buffer, drawn, mask: outline, blocked: blocked)
      expect(free[:coverage]).to be > 0.5 # grown past its own edge
      expect(held[:coverage]).to be_within(0.001).of(0.5)
      alpha = Vips::Image.new_from_buffer(held[:bytes], '').extract_band(3)
      expect(alpha.crop(150, 0, 150, 200).max).to eq(0)
    end

    it 'skips a surface the photo does not show, without paying for a finish drawing' do
      paints(photo)
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'skipped', error: 'Not in this photo')
      expect(Truebuild::Trueview::Providers::Gemini).to have_received(:edit).once
    end

    it 'keeps only the drawing inside the outline, whatever else the model changed' do
      paints(painted)
      allow(Truebuild::Trueview).to receive(:fetch_source).and_call_original
      allow(Truebuild::Trueview).to receive(:fetch_source) do |url|
        url.include?('masks/') ? { bytes: @stored_mask, mime: 'image/png' } : { bytes: photo.jpegsave_buffer, mime: 'image/jpeg' }
      end
      allow(Truebuild::Trueview).to receive(:store_bytes) { |b, _m, key| @stored_mask = b; "https://b/#{key}" }
      Truebuild::Trueview.perform!(render)
      expect(render.reload.status).to eq('done')
      expect(render.mask_coverage.to_f).to be_within(0.01).of(0.25)
    end

    it 'falls back to the change cut when outlining fails, and tries again later' do
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit).and_raise(Truebuild::Trueview::Error, 'Gemini 503')
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets')
      expect(mask).to have_attributes(status: 'failed', error: 'Gemini 503')
      expect(mask.present?).to be(false)
      mask.update_columns(updated_at: 1.hour.ago)
      paints(painted)
      expect(Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets').status).to eq('done')
    end
  end

  describe 'layer check' do
    before { allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(nil) }

    def draws(n_scores)
      scores = n_scores.dup
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: png((photo + 50).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |tool:, **|
        # A 4's second look agrees; the first look's scores drive these specs.
        next { input: { 'acceptable' => true }, input_tokens: 0, output_tokens: 0 } if tool[:name] == 'find_defects'

        expect(tool[:name]).to eq('judge_layer')
        { input: { 'score' => scores.shift, 'note' => 'The porch wall kept the old siding.' }, input_tokens: 2500, output_tokens: 40 }
      end
    end

    it 'shows a layer that passes' do
      draws([5])
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'done')
      expect(render.usage['check']).to include('score' => 5, 'ok' => true)
    end

    it "draws once more with the check's note, and shows it if that passes" do
      draws([3, 4])
      prompts = []
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |_s, _src, prompt, **|
        prompts << prompt
        { bytes: png((photo + 50).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
      end
      Truebuild::Trueview.perform!(render)
      expect(prompts.last).to end_with('A check of the last drawing found: The porch wall kept the old siding. Fix that.')
      expect(render.reload.status).to eq('done')
    end

    it 'keeps a layer that fails twice for review, hidden from buyers' do
      draws([2, 3])
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'rejected', error: 'Hidden: The porch wall kept the old siding.')
      expect(render.layer_url).to be_present
    end

    it "checks the layer against the factory's sample, so a wrong color fails" do
      mfr = Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home')
      swatch = CatalogSwatch.create!(manufacturer: mfr, set_name: 'Cabinets', name: 'Destin White', hex: '#f2f0ea', image_url: 'https://b/destin.jpg')
      render.update!(usage: { 'swatch_ids' => [swatch.id] })
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: png((photo + 50).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
      asked = []
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |content:, **|
        asked << content
        { input: { 'score' => 2, 'note' => 'The cabinets are cream, the sample is bright white.' }, input_tokens: 3000, output_tokens: 40 }
      end
      Truebuild::Trueview.perform!(render)
      expect(asked.first.count { |c| c[:type] == 'image' }).to eq(3)
      expect(asked.first.map { |c| c[:text] }.join).to include("factory's own sample of Destin White (measured color #f2f0ea)", 'score 2')
      expect(render.reload).to have_attributes(status: 'rejected', error: 'Hidden: The cabinets are cream, the sample is bright white.')
    end

    it 'draws nothing for a surface whose outline failed, rather than cut it by what changed' do
      failed = TruebuildSurfaceMask.new(status: 'failed', error: 'outline scored 2')
      allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(failed)
      expect(Truebuild::Trueview::Providers::Gemini).not_to receive(:edit)
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'failed', cost_usd: 0)
      expect(render.error).to start_with('Not drawn: no outline yet')
    end

    it 'tells the check that an added or doubled pull is wrong' do
      draws([5])
      asked = []
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |content:, **|
        asked << content.map { |c| c[:text] }.join
        { input: { 'score' => 5 }, input_tokens: 1, output_tokens: 1 }
      end
      Truebuild::Trueview.perform!(render)
      expect(asked.first).to include('a second pull or knob on a door')
      expect(Truebuild::Trueview.prompt(room: 'bath', selection: [{ 'surface' => 'Cabinets', 'value' => 'Timberwolf' }]))
        .to include('never add hardware')
    end

    it 'tries the larger model last, told everything the checks found, before holding a layer back' do
      models = []
      prompts = []
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |spec, _src, prompt, **|
        models << spec[:model]
        prompts << prompt
        { bytes: png((photo + 50).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
      end
      notes = ['Edges kept the old color.', 'The island base is unchanged.', nil]
      scores = [2, 3, 5]
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do
        { input: { 'score' => scores.shift, 'note' => notes.shift }, input_tokens: 1, output_tokens: 1 }
      end
      Truebuild::Trueview.perform!(render)
      expect(models).to eq(['gemini-3.1-flash-lite-image', 'gemini-3.1-flash-lite-image', 'gemini-3.1-flash-image'])
      expect(prompts.last).to end_with('Checks of the earlier drawings found: Edges kept the old color. The island base is unchanged. Fix all of that.')
      expect(render.reload).to have_attributes(status: 'done')
      expect(render.usage['escalated']).to be(true)
    end

    it 'takes a second, skeptical look at a 4, and holds the layer back if that finds a defect' do
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: png((photo + 50).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
      tools = []
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |tool:, **|
        tools << tool[:name]
        input = if tool[:name] == 'find_defects'
                  { 'acceptable' => false, 'spilled_onto' => 'The backsplash took the wall color.', 'old_finish_left' => 'none' }
                else
                  { 'score' => 4, 'note' => 'Small flaws.' }
                end
        { input: input, input_tokens: 1000, output_tokens: 50 }
      end
      verdict = Truebuild::Trueview::LayerCheck.judge(photo.jpegsave_buffer, png((photo + 50).cast(:uchar)), surface: 'Accent wall', value: 'Dogwood Harvest')
      expect(tools).to eq(%w[judge_layer find_defects])
      expect(verdict).to include('ok' => false, 'score' => 4, 'note' => 'The backsplash took the wall color.')
      expect(verdict['cost_usd']).to be > 0.003
    end

    it 'trusts a 5, and a 4 the second look accepts, without asking twice' do
      calls = Hash.new(0)
      answers = { 'judge_layer' => [{ 'score' => 5 }, { 'score' => 4 }], 'find_defects' => [{ 'acceptable' => true }] }
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |tool:, **|
        calls[tool[:name]] += 1
        { input: answers[tool[:name]].shift, input_tokens: 1, output_tokens: 1 }
      end
      layer = png((photo + 50).cast(:uchar))
      expect(Truebuild::Trueview::LayerCheck.judge(photo.jpegsave_buffer, layer, surface: 'Siding', value: 'Clay')['ok']).to be(true)
      expect(calls).to eq('judge_layer' => 1)
      expect(Truebuild::Trueview::LayerCheck.judge(photo.jpegsave_buffer, layer, surface: 'Siding', value: 'Clay')['ok']).to be(true)
      expect(calls).to eq('judge_layer' => 2, 'find_defects' => 1)
    end

    it "tells the drawing and the check what an abbreviated fridge looks like" do
      prompt = Truebuild::Trueview.prompt(room: 'kitchen', selection: [{ 'surface' => 'Refrigerator', 'value' => '21 CF Stnls SxS Refer w/ice IPO 18.2CF' }])
      expect(prompt).to include('which is stainless steel side-by-side refrigerator')
      expect(Truebuild::Trueview::LayerCheck.scope('Refrigerator', '20.5CF O/U Refer w/o Ice IPO 18.2'))
        .to include('it must show top-freezer refrigerator', 'A different style or finish is clearly wrong: score 2.')
    end

    it 'shows the layer when the check itself cannot run' do
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: png((photo + 50).cast(:uchar)), mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call).and_raise(Catalog::PriceBooks::ClaudeClient::Error, 'out of credits')
      Truebuild::Trueview.perform!(render)
      expect(render.reload.status).to eq('done')
      expect(render.usage.dig('check', 'note')).to start_with('Not checked')
    end
  end

  describe 'framing' do
    before do
      allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(nil)
      # The layer check passes; without this it calls Claude for real wherever a key is set.
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call).and_return(input: { 'score' => 5 }, input_tokens: 0, output_tokens: 0)
    end

    it 'asks for the photo shape and draws again when the model reframes, paying for both' do
      tall = png(Vips::Image.black(100, 300, bands: 3) + 90)
      wide = png((photo + 30).cast(:uchar))
      calls = 0
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |*_, aspect:, **|
        expect(aspect).to eq(1.5)
        calls += 1
        { bytes: calls == 1 ? tall : wide, mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
      end
      Truebuild::Trueview.perform!(render)
      expect(render.reload.status).to eq('done')
      expect(render.cost_usd.to_f).to eq(0.06) # two drawings at 1,000 tokens x $30/M
    end

    it 'gives up after two reframed drawings' do
      tall = png(Vips::Image.black(100, 300, bands: 3) + 90)
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: tall, mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'failed', error: "The model changed the photo's framing 2 times")
    end
  end

  it 'picks the closest aspect Gemini offers' do
    allow(Truebuild::Trueview::Providers::Gemini).to receive(:resolve) { |m| m }
    allow(Truebuild::Trueview::Providers::Gemini).to receive(:headers).and_return({})
    sent = nil
    allow(HTTParty).to receive(:post) { |_url, opts| sent = JSON.parse(opts[:body]); double(code: 500, parsed_response: {}, body: 'x') }
    expect do
      Truebuild::Trueview::Providers::Gemini.edit({ model: 'm', size: nil }, { bytes: 'x', mime: 'image/jpeg' }, 'p', aspect: 1600 / 1069.0)
    end.to raise_error(Truebuild::Trueview::Error)
    expect(sent.dig('generationConfig', 'imageConfig', 'aspectRatio')).to eq('3:2')
  end

  it 'fetches a photo whose address has spaces in it' do
    url = 'https://s7d9.scene7.com/is/image/championhomes/Aspire 3272H32186 Master Bath'
    expect(HTTParty).to receive(:get).with("#{url.gsub(' ', '%20')}?wid=1600&fmt=jpeg&qlt=90", timeout: 30)
                                     .and_return(instance_double(HTTParty::Response, code: 200, body: 'x', headers: {}))
    RSpec::Mocks.space.proxy_for(Truebuild::Trueview).reset
    expect(Truebuild::Trueview.fetch_source(url)[:bytes]).to eq('x')
  end
end
