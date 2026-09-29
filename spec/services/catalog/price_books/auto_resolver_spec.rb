# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

RSpec.describe Catalog::PriceBooks::AutoResolver do
  before { stub_private_files }

  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:company) { Company.create!(name: "Platform #{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!', first_name: 'P', last_name: 'A',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026', status: 'in_review') }

  def row(number, flags: [], **payload)
    book.import_items.create!(item_type: 'variant_price', flags: flags,
                              payload: { 'model_number' => number, 'net_base_price' => 50_000 }.merge(payload.stringify_keys))
  end

  it 'approves clean items and information-only flags, with the reason written on the item' do
    clean = row('2856H32392', width_ft: 28, length_ft: 56)
    scan = row('1456H22P01', flags: %w[model_number_normalized scanned_source])
    described_class.new(book, by: admin).call

    expect(clean.reload.review_status).to eq('approved')
    expect(scan.reload).to have_attributes(review_status: 'approved', reviewed_by_id: admin.id)
    expect(scan.payload['resolution']).to include('letter O')
  end

  it "keeps a 30' box Champion codes as 32, and corrects a length the name and number both contradict" do
    shelby = row('3260M32181', flags: ['model_code_width_mismatch'], width_ft: 30, length_ft: 60, model_name: "60' Shelby")
    lincoln = row('2848M32171', flags: ['model_code_length_mismatch'], width_ft: 28, length_ft: 52, model_name: "48' Lincoln")
    described_class.new(book, by: admin).call

    expect(shelby.reload).to have_attributes(review_status: 'approved')
    expect(shelby.payload['width_ft']).to eq(30)
    expect(lincoln.reload.review_status).to eq('edited')
    expect(lincoln.payload['length_ft']).to eq(48)
    expect(lincoln.payload['resolution']).to include('both say 48')
  end

  it 'leaves real decisions for a person and reports why' do
    apex = row('2856H32P01', flags: %w[model_code_beds_mismatch scanned_source], beds: 4)
    unsure = row('1666H32P09', flags: ['read_uncertain'])
    removed = book.import_items.create!(item_type: 'variant_price', change_type: 'removed', flags: ['missing_from_new_book'],
                                        payload: { 'model_number' => '2848H32024' })
    result = described_class.new(book, by: admin).call

    expect([apex, unsure, removed].map { |i| i.reload.review_status }).to all(eq('pending'))
    expect(result.needs_you).to eq(3)
    expect(result.reasons).to include('model_code_beds_mismatch' => 1, 'read_uncertain' => 1)
    expect(book.reload.metadata['auto_resolve']).to include('needs_you' => 3)
  end

  it 'approves an uncertain row when a second read agrees, and keeps it when it does not' do
    agree = row('1672H32P09', flags: ['read_uncertain'], beds: 3, baths: 2, width_ft: 16, length_ft: 72)
    differ = row('1672H32P07', flags: ['read_uncertain'], beds: 3, baths: 2, width_ft: 16, length_ft: 72)
    doc = book.documents.create!(filename: 'prime.pdf', checksum_sha256: 'x', storage_bucket: 'dt-private-test', storage_key: 'k')
    [agree, differ].each { |i| i.update!(document: doc, source_ref: { 'page' => 1 }) }
    allow(PrivateFiles).to receive(:read).and_return('%PDF-1.4')
    client = double(call: { input: { 'rows' => [
      { 'model_number' => '1672H32P09', 'net_base_price' => 50_000, 'beds' => 3, 'baths' => 2 },
      { 'model_number' => '1672H32P07', 'net_base_price' => 39_710, 'beds' => 3, 'baths' => 2 }
    ] }, stop_reason: 'tool_use', input_tokens: 10, output_tokens: 10 })

    verifier = Catalog::PriceBooks::SecondReader.new(book, client: client)
    described_class.new(book, by: admin, verifier: verifier).call

    expect(agree.reload.review_status).to eq('approved')
    expect(agree.payload['resolution']).to include('second read')
    expect(differ.reload.review_status).to eq('pending')
    expect(differ.payload.dig('second_read', 'net_base_price')).to eq(39_710)
  end
end

RSpec.describe Catalog::PriceBooks::Recorder do
  before { stub_private_files }

  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026') }

  it 'records spend on the file after each call and stops at the cap' do
    stub_const('ENV', ENV.to_h.merge('PRICE_BOOK_BUDGET_USD' => '1'))
    doc = book.documents.create!(filename: 'options.xlsx', checksum_sha256: 'y')
    # 100k output tokens at $15 per million is $1.50: over a $1 cap after one call.
    client = double(call: { input: {}, stop_reason: 'tool_use', input_tokens: 0, output_tokens: 100_000 })
    recorder = described_class.new(book, client: client, document: doc)

    recorder.claude(content: [], tool: Catalog::PriceBooks::Tools::CLASSIFY, system: '')
    expect(doc.reload.metadata.dig('usage', 'cost_usd')).to eq(1.5)
    expect { recorder.claude(content: [], tool: Catalog::PriceBooks::Tools::CLASSIFY, system: '') }
      .to raise_error(Catalog::PriceBooks::ExtractionError, /\$1 spending cap/)
  end
end
