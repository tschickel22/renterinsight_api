# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Batch do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka 2026', status: 'published') }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, factory: topeka, key: 'exterior', name: 'Exterior', position: 5) }
  let(:front) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1' }
  let(:photo) { (Vips::Image.black(300, 200, bands: 3) + [150, 140, 130]).cast(:uchar) }
  let!(:home) do
    plan = CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Aspire', name: 'Belvidere', slug: "belvidere-#{SecureRandom.hex(2)}")
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56,
                               media: { 'photos' => [{ 'url' => front, 'room' => 'exterior' }] }).tap do |v|
      CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 90_000)
    end
  end
  let(:run_api) { Truebuild::Trueview::FactoryRun }

  def color(name)
    o = CatalogOption.create!(group: exterior, manufacturer: mfr, key: "exterior--siding-#{name}".parameterize, name: name,
                              kind: 'color', metadata: { 'color_set' => 'Siding' })
    CatalogOptionPrice.create!(price_book: book, option: o, is_standard: true)
  end

  def png(image) = image.cast(:uchar).pngsave_buffer

  def response_for(image)
    { 'candidates' => [{ 'content' => { 'parts' => [{ 'inlineData' => { 'mimeType' => 'image/png', 'data' => Base64.strict_encode64(png(image)) } }] } }],
      'usageMetadata' => { 'promptTokenCount' => 0, 'candidatesTokenCount' => 1000 } }
  end

  around do |ex|
    old = ENV['GEMINI_API_KEY']
    ENV['GEMINI_API_KEY'] = 'test'
    ex.run
  ensure
    ENV['GEMINI_API_KEY'] = old
  end

  before do
    color('White')
    color('Clay')
    allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(nil)
    allow(Truebuild::Trueview).to receive(:fetch_source) { |url| { bytes: url.include?('drawn') ? png((photo + 50).cast(:uchar)) : photo.jpegsave_buffer, mime: 'image/jpeg' } }
    allow(Truebuild::Trueview).to receive(:store) { |r, _b, _m, **o| "https://b/drawn-#{r.id}-#{o[:suffix] || 'full'}" }
    allow(Truebuild::Trueview::Providers::Gemini).to receive(:resolve) { |m| m }
  end

  it 'sends a batch run its drawings by batch, at half price, and checks each as it comes back' do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin, batch: true)
    # Drawings at the batch rate; outlines are still made immediately, at the full rate.
    expect(run_api.estimate([home], batch: true)[:rates][:layer]).to eq((run_api.estimate([home])[:rates][:layer] / 2).round(4))
    expect(run.estimate['cost_usd']).to eq(run_api.estimate([home], batch: true)[:totals][:cost_usd])
    TruebuildFactoryRunJob.perform_now(run.id)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j[:job] }).not_to include(TruebuildRenderJob)
    expect(described_class.waiting(run).count).to eq(2)

    sent = nil
    allow(Truebuild::Trueview::GeminiBatch).to receive(:submit) { |model, lines, **| sent = [model, lines]; 'batches/abc' }
    expect(described_class.submit!(run)).to eq(2)
    expect(sent.first).to eq('gemini-3.1-flash-lite-image')
    expect(sent.last.map(&:first)).to match_array(run.renders.map { |r| "r#{r.id}" })
    expect(run_api.progress(run.reload)[:phase]).to eq('waiting_on_google')

    allow(Truebuild::Trueview::GeminiBatch).to receive(:status).and_return(done: true, failed: false, state: 'JOB_STATE_SUCCEEDED', responses_file: 'files/out')
    allow(Truebuild::Trueview::GeminiBatch).to receive(:results)
      .and_return([run.renders.to_h { |r| ["r#{r.id}", response_for((photo + 50).cast(:uchar))] }, {}])
    expect { described_class.poll!(run) }.to have_enqueued_job(TruebuildBatchDrawingJob).twice
    full = Truebuild::Trueview.cost(Truebuild::Trueview::MODELS['nb2-lite'], 'prompt_tokens' => 0, 'output_tokens' => 1000)
    expect(run.renders.pluck(:cost_usd).map(&:to_f).uniq).to eq([(full / 2).round(4)])

    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call).and_return(input: { 'score' => 5 }, input_tokens: 0, output_tokens: 0)
    run.renders.each { |r| TruebuildBatchDrawingJob.perform_now(r.id) }
    expect(run.renders.pluck(:status).uniq).to eq(['done'])
  end

  it 'sends a failed drawing to the next batch with what the check found, then to the larger model' do
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin, batch: true)
    TruebuildFactoryRunJob.perform_now(run.id)
    render = run.renders.first
    notes = ['The porch wall kept the old siding.', 'Still patchy.', nil]
    scores = [2, 3, 5]
    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) { { input: { 'score' => scores.shift, 'note' => notes.shift }, input_tokens: 0, output_tokens: 0 } }

    models = []
    prompts = []
    3.times do
      render.update!(status: 'running', usage: render.reload.usage.merge('batch_model' => described_class.next_model(render), 'batch_drawn' => 'https://b/drawn'))
      models << render.usage['batch_model']
      prompts << described_class.asked(render, 'p', render.usage['batch_model'])
      described_class.check!(render)
      break if render.reload.status == 'done'
    end
    expect(models).to eq(%w[nb2-lite nb2-lite nb2])
    expect(prompts.last).to eq("p\n\nChecks of the earlier drawings found: The porch wall kept the old siding. Still patchy. Fix all of that.")
    expect(render.reload).to have_attributes(status: 'done')
    expect(render.usage['escalated']).to be(true)
  end

  it 'starts a scheduled run when its time comes, and tells the admin how a run ended' do
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin, batch: true, at: 3.hours.from_now)
    expect(run).to have_attributes(status: 'scheduled', mode: 'batch')
    expect(run_api.progress(run)[:phase]).to eq('scheduled')
    expect { TruebuildFactoryRunTickJob.perform_now }.not_to have_enqueued_job(TruebuildFactoryRunJob)

    run.update_columns(scheduled_at: 1.minute.ago)
    allow(described_class).to receive(:submit!).and_return(0)
    expect { TruebuildFactoryRunTickJob.perform_now }.to have_enqueued_job(TruebuildFactoryRunJob).with(run.id)
    expect(run.reload.status).to eq('running')

    run.stop!
    note = Notification.where(recipient: admin).last
    expect(note).to have_attributes(notification_type: 'truebuild_factory_run', title: 'TrueView factory run was stopped')
  end

  it 'still collects the drawings already at Google when a batch run is stopped, and sends no more' do
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin, batch: true)
    TruebuildFactoryRunJob.perform_now(run.id)
    allow(Truebuild::Trueview::GeminiBatch).to receive(:submit).and_return('batches/abc')
    described_class.submit!(run)
    run.reload.stop!
    expect(run.renders.pluck(:status).uniq).to eq(['running']) # paid for: not cancelled

    allow(Truebuild::Trueview::GeminiBatch).to receive(:status).and_return(done: true, failed: false, state: 'JOB_STATE_SUCCEEDED', responses_file: 'files/out')
    allow(Truebuild::Trueview::GeminiBatch).to receive(:results)
      .and_return([run.renders.to_h { |r| ["r#{r.id}", response_for((photo + 50).cast(:uchar))] }, {}])
    expect(described_class).not_to receive(:submit!)
    expect { TruebuildFactoryRunTickJob.perform_now }.to have_enqueued_job(TruebuildBatchDrawingJob).twice
  end

  it 'recovers drawings a deploy left halfway: prepared but not sent, or returned but not checked' do
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin, batch: true)
    TruebuildFactoryRunJob.perform_now(run.id)
    unsent, unchecked = run.renders.order(:id).to_a
    unsent.update_columns(status: 'running', updated_at: 1.hour.ago)
    unchecked.update_columns(status: 'running', usage: unchecked.usage.merge('batch_drawn' => 'https://b/d'), updated_at: 1.hour.ago)
    expect { expect(described_class.recover!(run)).to eq(2) }.to have_enqueued_job(TruebuildBatchDrawingJob).with(unchecked.id)
    expect(unsent.reload.status).to eq('queued')
  end

  it 'puts back work a deploy dropped from a run nobody is watching' do
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin)
    run.update_columns(updated_at: 1.hour.ago) # queuing dropped, Factory Runs page closed
    expect { TruebuildFactoryRunTickJob.perform_now }.to have_enqueued_job(TruebuildFactoryRunJob).with(run.id)
  end

  it 'waits a drawing whose batch could not be sent for the next one, a few times' do
    run = run_api.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }, by: admin, batch: true)
    TruebuildFactoryRunJob.perform_now(run.id)
    allow(Truebuild::Trueview::GeminiBatch).to receive(:submit).and_raise(Truebuild::Trueview::Error, 'quota')
    3.times { described_class.submit!(run) }
    expect(run.renders.pluck(:status).uniq).to eq(['failed'])
    expect(run.renders.first.error).to eq('Batch: quota')
  end
end
