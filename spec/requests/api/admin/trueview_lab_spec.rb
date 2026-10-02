# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Admin::TrueviewLab', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let(:kitchen_photo) { 'https://s7d9.scene7.com/is/image/championhomes/bay-port-kitchen-1' }
  let!(:variant) do
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56,
                               media: { 'name' => 'Aspire Bay Port', 'photos' => [{ 'url' => kitchen_photo, 'room' => 'kitchen' }] })
  end
  let(:finishes) { [{ surface: 'Cabinets', value: 'Timberwolf' }, { surface: 'Countertops', value: 'Calcutta Marble' }] }

  def headers_for(role)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S',
                        password: 'Pass1234!', company_id: company.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  let(:admin) { headers_for('platform_admin') }

  # Outlines are covered in trueview_render_spec; here layers use the change-based cut.
  # The layer check passes; without this it calls Claude for real wherever a key is set.
  before do
    allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(nil)
    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call).and_return(input: { 'score' => 5 }, input_tokens: 0, output_tokens: 0)
  end

  around do |ex|
    old = ENV.values_at('GEMINI_API_KEY', 'OPENAI_API_KEY')
    ENV['GEMINI_API_KEY'] = 'test-gemini'
    ENV.delete('OPENAI_API_KEY')
    ex.run
  ensure
    ENV['GEMINI_API_KEY'], ENV['OPENAI_API_KEY'] = old
  end

  def run!(extra = {})
    post '/api/admin/trueview_lab/runs', headers: admin,
         params: { variant_id: variant.id, source_url: kitchen_photo, finishes: finishes, models: %w[nb2 gpt-image-2-high] }.merge(extra).to_json
  end

  it 'is for platform admins only' do
    get '/api/admin/trueview_lab', headers: headers_for('sales')
    expect(response).to have_http_status(:forbidden)
  end

  it 'lists models with photos and which image models have keys' do
    get '/api/admin/trueview_lab', headers: admin
    body = JSON.parse(response.body)
    expect(body['variants'].map { |v| v['id'] }).to include(variant.id)
    expect(body['models'].find { |m| m['key'] == 'nb2' }['configured']).to be(true)
    expect(body['models'].find { |m| m['key'] == 'gpt-image-2-high' }['configured']).to be(false)
  end

  it 'queues one rendering per image model and says when a key is missing' do
    expect { run! }.to have_enqueued_job(TruebuildRenderJob).once
    body = JSON.parse(response.body)
    expect(response).to have_http_status(:created)
    expect(body['renders'].map { |r| [r['model_key'], r['status']] }).to eq([%w[nb2 queued], %w[gpt-image-2-high failed]])
    expect(body['renders'].last['error']).to include('OPENAI_API_KEY')
    expect(body['prompt']).to include('Cabinets: Timberwolf (color #8a867e)', 'Do not add, remove or move any object')
  end

  it 'only renders photos that belong to the model' do
    run!(source_url: 'http://169.254.169.254/latest/meta-data')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(TruebuildRender.count).to eq(0)
  end

  it 'serves a repeated combination from the cache at no cost, in any finish order' do
    TruebuildRender.create!(catalog_plan_variant: variant, source_url: kitchen_photo, selection: TruebuildRender.normalize(finishes.map(&:stringify_keys)),
                            selection_key: TruebuildRender.key_for(finishes.reverse.map(&:stringify_keys)), model_key: 'nb2',
                            provider: 'gemini', model: 'gemini-3.1-flash-image', status: 'done', image_url: 'https://s3/x.png', cost_usd: 0.07,
                            prompt: Truebuild::Trueview.prompt(room: 'kitchen', selection: finishes.map(&:stringify_keys)))
    expect { run!(models: %w[nb2]) }.not_to have_enqueued_job(TruebuildRenderJob)
    render = JSON.parse(response.body)['renders'].first
    expect(render).to include('status' => 'done', 'image_url' => 'https://s3/x.png', 'cost_usd' => 0.0, 'cached' => true)
  end

  it 'renders, stores and prices a queued row' do
    run!(models: %w[nb2])
    row = TruebuildRender.last
    image = (Vips::Image.black(300, 200, bands: 3) + 120).cast(:uchar)
    allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: image.jpegsave_buffer, mime: 'image/jpeg')
    allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
      .and_return(bytes: image.pngsave_buffer, mime: 'image/png', model: 'gemini-3.1-flash-image-preview',
                  usage: { 'prompt_tokens' => 1500, 'output_tokens' => 1680 })
    allow(Truebuild::Trueview).to receive(:store).and_return('https://bucket/truebuild/trueview/a.png')

    TruebuildRenderJob.perform_now(row.id)
    row.reload
    expect(row.status).to eq('done')
    expect(row.model).to eq('gemini-3.1-flash-image-preview')
    expect(row.cost_usd.to_f).to eq(0.1016) # 1,500 x $0.50/M + 1,680 x $60/M
  end

  it 'records a provider failure on the row' do
    run!(models: %w[nb2])
    allow(Truebuild::Trueview).to receive(:fetch_source).and_raise(Truebuild::Trueview::Error, 'Source photo returned 404')
    TruebuildRenderJob.perform_now(TruebuildRender.last.id)
    expect(TruebuildRender.last).to have_attributes(status: 'failed', error: 'Source photo returned 404')
  end

  describe 'layers' do
    def layers!(extra = {})
      post '/api/admin/trueview_lab/runs', headers: admin, params: {
        mode: 'layers', variant_id: variant.id, source_url: kitchen_photo, model: 'nb2-lite',
        layers: [{ surface: 'Cabinets', values: %w[Timberwolf Destin\ White] }, { surface: 'Countertop', values: ['Calcutta'] }]
      }.merge(extra).to_json
    end

    it 'draws each finish on its own with one image model' do
      expect { layers! }.to have_enqueued_job(TruebuildRenderJob).exactly(3).times
      body = JSON.parse(response.body)
      expect(body['mode']).to eq('layers')
      expect(body['renders'].map { |r| [r['surface'], r['value']] })
        .to contain_exactly(%w[Cabinets Timberwolf], ['Cabinets', 'Destin White'], %w[Countertop Calcutta])
      expect(TruebuildRender.pluck(:purpose).uniq).to eq(['layer'])
    end

    it 'cuts the drawn finish out of the photo' do
      layers!(layers: [{ surface: 'Cabinets', values: ['Timberwolf'] }])
      base = (Vips::Image.black(400, 300, bands: 3) + [120, 110, 100]).cast(:uchar)
      drawn = base.draw_rect([30, 60, 200], 100, 100, 120, 80, fill: true).resize(0.64).cast(:uchar)
      allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: base.jpegsave_buffer(Q: 95), mime: 'image/jpeg')
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: drawn.pngsave_buffer, mime: 'image/png', usage: { 'prompt_tokens' => 10, 'output_tokens' => 1120 })
      stored = []
      allow(Truebuild::Trueview).to receive(:store) { |_r, bytes, mime, **opts| stored << [mime, opts[:suffix]]; "https://b/#{opts[:suffix] || 'full'}" }

      TruebuildRenderJob.perform_now(TruebuildRender.last.id)
      row = TruebuildRender.last
      expect(row).to have_attributes(status: 'done', layer_url: 'https://b/layer')
      expect(row.mask_coverage.to_f).to be_within(0.02).of(0.08)
      expect(stored).to eq([['image/png', nil], ['image/webp', 'layer']])
    end

    it 'reuses a layer only when it was drawn with the current instructions' do
      layers!(layers: [{ surface: 'Cabinets', values: ['Timberwolf'] }])
      TruebuildRender.last.update!(status: 'done', image_url: 'https://b/i.png', layer_url: 'https://b/l.webp',
                                   usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      get '/api/admin/trueview_lab/drawn', headers: admin, params: { variant_id: variant.id, source_url: kitchen_photo, model: 'nb2-lite' }
      expect(JSON.parse(response.body)['finishes']).to eq([{ 'surface' => 'Cabinets', 'value' => 'Timberwolf' }])
      expect { layers!(layers: [{ surface: 'Cabinets', values: ['Timberwolf'] }]) }.not_to have_enqueued_job(TruebuildRenderJob)

      TruebuildRender.update_all(prompt: 'older instructions')
      get '/api/admin/trueview_lab/drawn', headers: admin, params: { variant_id: variant.id, source_url: kitchen_photo, model: 'nb2-lite' }
      expect(JSON.parse(response.body)['finishes']).to eq([])
      expect { layers!(layers: [{ surface: 'Cabinets', values: ['Timberwolf'] }]) }.to have_enqueued_job(TruebuildRenderJob)
    end

    it 'tells the model what each surface covers' do
      prompt = Truebuild::Trueview.prompt(room: 'kitchen', selection: [{ 'surface' => 'Cabinets', 'value' => 'Destin White' }])
      expect(prompt).to include('including the island base')
      expect(Truebuild::Trueview.prompt(room: 'kitchen', selection: [{ 'surface' => 'Accent wall', 'value' => 'Jurupa' }]))
        .to include('ONE wall only')
    end

    it 'cuts an old layer again from its saved drawing without calling the image model' do
      layers!(layers: [{ surface: 'Flooring', values: ['9701 - Serenity'] }])
      old = TruebuildRender.last
      old.update!(status: 'done', image_url: 'https://b/drawn.png', layer_url: 'https://b/old.webp', cost_usd: 0.042, usage: { 'mask_version' => 1 })

      expect { layers!(layers: [{ surface: 'Flooring', values: ['9701 - Serenity'] }]) }.to have_enqueued_job(TruebuildRenderJob)
      row = TruebuildRender.last
      expect(row.usage).to include('recut_from' => old.id)

      base = (Vips::Image.black(80, 60, bands: 3) + 150).cast(:uchar)
      allow(Truebuild::Trueview).to receive(:fetch_source) { |url| { bytes: (url.include?('drawn') ? base + 40 : base).cast(:uchar).pngsave_buffer, mime: 'image/png' } }
      allow(Truebuild::Trueview).to receive(:store).and_return('https://b/new.webp')
      expect(Truebuild::Trueview::Providers::Gemini).not_to receive(:edit)
      TruebuildRenderJob.perform_now(row.id)
      expect(row.reload).to have_attributes(status: 'done', layer_url: 'https://b/new.webp', cost_usd: 0)
      expect(row.usage['mask_version']).to eq(Truebuild::Trueview::Layer::VERSION)
    end

    it 'caps a run at 40 finishes' do
      layers!(layers: [{ surface: 'Backsplash', values: (1..41).map { |i| "Tile #{i}" } }])
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'review and flag' do
    let!(:layer) do
      TruebuildRender.create!(catalog_plan_variant: variant, source_url: kitchen_photo, room: 'kitchen', purpose: 'layer',
                              selection: [{ 'surface' => 'Cabinets', 'value' => 'Timberwolf' }], selection_key: 'k1', model_key: 'nb2-lite',
                              provider: 'gemini', model: 'lite', prompt: 'p', status: 'done', image_url: 'https://b/i.png',
                              layer_url: 'https://b/l.webp', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION, 'swatch_ids' => [] })
    end
    let!(:outline) do
      TruebuildSurfaceMask.create!(source_url: kitchen_photo, surface: 'cabinets', version: Truebuild::Trueview::Surfaces::VERSION,
                                   mask_url: 'https://b/m.png', coverage: 0.12, error: 'Covers the stools a little.',
                                   usage: { 'attempts' => [{ 'present' => true, 'fit' => 4 }], 'cost_usd' => 0.05 })
    end

    it "shows a model's outlines and layers per photo" do
      get '/api/admin/trueview_lab/review', headers: admin, params: { variant_id: variant.id }
      photo = JSON.parse(response.body)['photos'].first
      expect(photo['outlines'].first).to include('surface' => 'cabinets', 'fit' => 4, 'used' => true, 'note' => 'Covers the stools a little.')
      expect(photo['layers'].first).to include('value' => 'Timberwolf', 'layer_url' => 'https://b/l.webp')
    end

    it 'takes a flagged layer away from buyers and draws it again with the note' do
      expect do
        post "/api/admin/trueview_lab/layers/#{layer.id}/flag", headers: admin, params: { note: 'Paint ran onto the floor.' }.to_json
      end.to have_enqueued_job(TruebuildRenderJob)
      expect(layer.reload).to have_attributes(status: 'flagged', error: 'Paint ran onto the floor.')
      again = TruebuildRender.last
      expect(again).to have_attributes(status: 'queued', prompt: 'p', image_url: nil)
      expect(again.usage).to include('reviewer_note' => 'Paint ran onto the floor.', 'flagged_from' => layer.id)

      image = (Vips::Image.black(300, 200, bands: 3) + 120).cast(:uchar)
      allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: image.jpegsave_buffer, mime: 'image/jpeg')
      allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(nil)
      allow(Truebuild::Trueview).to receive(:store).and_return('https://b/new.webp')
      sent = nil
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |_s, _src, prompt, **|
        sent = prompt
        { bytes: image.pngsave_buffer, mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
      end
      TruebuildRenderJob.perform_now(again.id)
      expect(sent).to end_with('A reviewer rejected an earlier drawing: Paint ran onto the floor. Fix that.')
      expect(again.reload.status).to eq('done')
    end

    it "finishes a drawing whose worker a deploy stopped, and requeues one left behind" do
      layer.update!(status: 'running', usage: layer.usage.merge('job_id' => 'job-1'))
      job = TruebuildRenderJob.new(layer.id)
      allow(job).to receive(:job_id).and_return('job-1')
      expect(Truebuild::Trueview).to receive(:perform!).with(layer)
      job.perform(layer.id)

      other = TruebuildRenderJob.new(layer.id)
      allow(other).to receive(:job_id).and_return('job-2')
      expect(Truebuild::Trueview).not_to receive(:perform!)
      other.perform(layer.id)

      layer.update_columns(updated_at: 1.hour.ago)
      expect { get '/api/admin/trueview_lab/review', headers: admin, params: { variant_id: variant.id } }
        .to have_enqueued_job(TruebuildRenderJob).with(layer.id)
      expect(layer.reload.status).to eq('queued')
    end

    it 'outlines a flagged surface again and cuts its layers again for free' do
      expect do
        post "/api/admin/trueview_lab/outlines/#{outline.id}/flag", headers: admin, params: { note: 'Leave the stools out.' }.to_json
      end.to have_enqueued_job(TruebuildOutlineRedoJob).with(outline.id, 'Leave the stools out.')

      image = (Vips::Image.black(300, 200, bands: 3) + 120).cast(:uchar)
      allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: image.jpegsave_buffer, mime: 'image/jpeg')
      allow(Truebuild::Trueview::Surfaces).to receive(:find!) do |*_, correction:|
        expect(correction).to eq('Leave the stools out.')
        TruebuildSurfaceMask.create!(source_url: kitchen_photo, surface: 'cabinets', version: Truebuild::Trueview::Surfaces::VERSION,
                                     mask_url: 'https://b/m2.png', coverage: 0.11)
      end
      expect { TruebuildOutlineRedoJob.perform_now(outline.id, 'Leave the stools out.') }.to have_enqueued_job(TruebuildRenderJob)
      expect(layer.reload.status).to eq('superseded')
      expect(TruebuildRender.last.usage).to include('recut_from' => layer.id)
    end
  end

  describe 'photos, held back layers and what needs review' do
    let(:k1) { 'https://s7d9.scene7.com/is/image/championhomes/bay-port-kitchen-2' }
    let(:k2) { 'https://s7d9.scene7.com/is/image/championhomes/bay-port-kitchen-3' }
    let(:den) { 'https://s7d9.scene7.com/is/image/championhomes/bay-port-den' }

    before do
      variant.update!(media: { 'name' => 'Aspire Bay Port', 'photos' => [{ 'url' => kitchen_photo, 'room' => 'kitchen' },
                                                                         { 'url' => k1, 'room' => 'kitchen' },
                                                                         { 'url' => k2, 'room' => 'kitchen' },
                                                                         { 'url' => den, 'room' => nil }] })
    end

    it "uses an admin's choice, else Claude's pick, else the first labelled photo" do
      choice = Truebuild::Trueview::PhotoChoice
      expect(choice.photos(variant)).to eq([['kitchen', kitchen_photo]])
      expect(choice.needs_pick?(variant)).to be(true)

      allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: (Vips::Image.black(40, 30, bands: 3) + 99).cast(:uchar).jpegsave_buffer, mime: 'image/jpeg')
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call).and_return(input: { 'photo' => 2 }, input_tokens: 1, output_tokens: 1)
      choice.pick!(variant)
      expect(choice.photos(variant.reload)).to eq([['kitchen', k1]])
      expect(choice.needs_pick?(variant)).to be(false)

      post '/api/admin/trueview_lab/photos', headers: admin, params: { variant_id: variant.id, room: 'kitchen', urls: [k2, den, 'https://evil.example/x.jpg'] }.to_json
      expect(JSON.parse(response.body)).to include('chosen' => [k2, den], 'source' => 'chosen')
      expect(choice.photos(variant.reload)).to eq([['kitchen', k2], ['kitchen', den]])

      get '/api/admin/trueview_lab/review', headers: admin, params: { variant_id: variant.id }
      room = JSON.parse(response.body)['rooms'].find { |r| r['room'] == 'kitchen' }
      expect(room['candidates'].map { |c| c['url'] }).to eq([kitchen_photo, k1, k2, den])
      expect(room['candidates'].last['labelled']).to be(false)
    end

    it 'hides a photo from buyers and TrueView, and brings it back' do
      variant.update_columns(media: variant.media.merge('elevations' => ['https://s7d9.scene7.com/elev'],
                                                        'trueview_photos' => { 'kitchen' => [k1, k2] }, 'trueview_auto' => { 'kitchen' => k1 }))

      post '/api/admin/trueview_lab/photos/hide', headers: admin, params: { variant_id: variant.id, url: k1, hidden: true }.to_json
      expect(response).to have_http_status(:ok)
      media = variant.reload.media
      expect(media).to include('hidden_photos' => [k1], 'trueview_photos' => { 'kitchen' => [k2] }, 'trueview_auto' => {})
      expect(variant.shown_media['photos'].map { |p| p['url'] }).not_to include(k1)
      expect(Truebuild::Trueview::PhotoChoice.candidate_urls(media, 'kitchen', all: true)).not_to include(k1)

      get '/api/admin/trueview_lab/review', headers: admin, params: { variant_id: variant.id }
      body = JSON.parse(response.body)
      gallery = body['gallery']
      kitchen = body['rooms'].find { |r| r['room'] == 'kitchen' }
      expect(kitchen['candidates'].find { |c| c['url'] == k1 }).to include('hidden' => true) # stays in place, marked
      expect(kitchen['chosen']).not_to include(k1)
      expect(gallery.find { |g| g['url'] == k1 }).to include('hidden' => true, 'room' => 'kitchen')
      expect(gallery.last).to include('url' => 'https://s7d9.scene7.com/elev', 'room' => nil)

      post '/api/admin/trueview_lab/photos/hide', headers: admin, params: { variant_id: variant.id, url: 'https://s7d9.scene7.com/elev', hidden: true }.to_json
      expect(variant.reload.shown_media['elevations']).to eq([])

      post '/api/admin/trueview_lab/photos/hide', headers: admin, params: { variant_id: variant.id, url: k1, hidden: false }.to_json
      expect(variant.reload.hidden_photo_urls).to eq(['https://s7d9.scene7.com/elev'])
      expect(variant.shown_media['photos'].map { |p| p['url'] }).to include(k1)

      post '/api/admin/trueview_lab/photos/hide', headers: admin, params: { variant_id: variant.id, url: 'https://evil.example/x.jpg', hidden: true }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'lets a reviewer show a held back layer, and lists models needing review worst first' do
      row = TruebuildRender.create!(catalog_plan_variant: variant, source_url: kitchen_photo, room: 'kitchen', purpose: 'layer',
                                    selection: [{ 'surface' => 'Cabinets', 'value' => 'Timberwolf' }], selection_key: 'k9',
                                    model_key: 'nb2-lite', provider: 'gemini', model: 'lite', prompt: 'p', status: 'rejected',
                                    error: 'Hidden: smear on the island', layer_url: 'https://b/l.webp',
                                    usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION, 'check' => { 'score' => 3 } })
      get '/api/admin/trueview_lab/attention', headers: admin
      expect(JSON.parse(response.body)['items'].first).to include('variant_id' => variant.id, 'held_back' => 1)

      post "/api/admin/trueview_lab/layers/#{row.id}/approve", headers: admin
      expect(row.reload).to have_attributes(status: 'done', error: nil)
      expect(row.usage['approved']).to be_present
    end
  end

  describe 'factory runs' do
    let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
    before { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 90_000) }

    it 'lists what can be run, estimates it, starts, shows and stops a run' do
      get '/api/admin/trueview_lab/factory_runs/scopes', headers: admin
      scope = JSON.parse(response.body).find { |m| m['id'] == mfr.id }
      expect(scope['factories']).to eq([{ 'id' => factory.id, 'name' => 'Topeka' }])
      expect(scope['series']).to eq([{ 'factory_id' => factory.id, 'series' => 'Aspire' }])

      get '/api/admin/trueview_lab/factory_runs/estimate', headers: admin, params: { manufacturer_id: mfr.id, factory_id: factory.id }
      expect(JSON.parse(response.body)['models'].map { |m| m['id'] }).to eq([variant.id])
      get '/api/admin/trueview_lab/factory_runs/estimate', headers: admin, params: { manufacturer_id: mfr.id, variant_ids: [0] }
      expect(JSON.parse(response.body)['models']).to eq([]) # only the models ticked

      post '/api/admin/trueview_lab/factory_runs', headers: admin, params: { manufacturer_id: mfr.id, factory_id: factory.id }.to_json
      expect(response).to have_http_status(:unprocessable_entity) # no budget

      post '/api/admin/trueview_lab/factory_runs', headers: admin, params: { manufacturer_id: mfr.id, factory_id: factory.id, budget_usd: 20 }.to_json
      expect(response).to have_http_status(:created)
      run_id = JSON.parse(response.body)['id']
      post '/api/admin/trueview_lab/factory_runs', headers: admin, params: { manufacturer_id: mfr.id, factory_id: factory.id, budget_usd: 20 }.to_json
      expect(JSON.parse(response.body)['error']).to eq('A run for this is already going')

      get '/api/admin/trueview_lab/factory_runs', headers: admin
      expect(JSON.parse(response.body).first).to include('id' => run_id, 'phase' => 'queuing', 'budget_usd' => 20.0)

      post "/api/admin/trueview_lab/factory_runs/#{run_id}/stop", headers: admin
      expect(JSON.parse(response.body)['phase']).to eq('stopped')
    end

    it 'is for platform admins only' do
      get '/api/admin/trueview_lab/factory_runs', headers: headers_for('company_admin')
      expect(response).to have_http_status(:forbidden)
    end
  end
end
