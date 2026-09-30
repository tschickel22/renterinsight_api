# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

# The price book pipeline with a fake model: what gets stored, what the
# deterministic checks catch, and what publishing writes to the catalog.
RSpec.describe 'TrueBuild price book pipeline' do
  # Answers each tool call with the next scripted response for that tool.
  class FakeClaude
    attr_reader :calls

    def initialize(script)
      @script = script.transform_values { |v| Array(v).dup }
      @calls = []
    end

    def call(content:, tool:, system:, max_tokens:)
      @calls << { tool: tool[:name], content: content }
      answer = @script.fetch(tool[:name]).shift || {}
      answer = answer.call(content) if answer.respond_to?(:call)
      { input: answer.deep_stringify_keys, stop_reason: 'tool_use', input_tokens: 100, output_tokens: 50 }
    end
  end

  let!(:s3) { stub_private_files }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_housing') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}", city: 'Topeka', state: 'IN') }
  let(:company) { Company.create!(name: "Platform #{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!', first_name: 'P', last_name: 'A',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', created_by: admin) }

  def upload(name, bytes, type = 'application/octet-stream')
    ActionDispatch::Http::UploadedFile.new(tempfile: Tempfile.new.tap { |t| t.binmode; t.write(bytes); t.rewind },
                                           filename: name, type: type)
  end

  def price_list_pdf
    Prawn::Document.new do |pdf|
      pdf.text 'DUTCH HOUSING ASPIRE HUD Net Pricing FOB Topeka, IN'
      pdf.text "2856H32392   28' x 56'   Belvidere   3  2   $57,995"
      pdf.text "3260H32181   30' x 60'   60' Shelby  3  2   $67,395"
    end.render
  end

  def workbook
    pkg = Axlsx::Package.new
    pkg.workbook.add_worksheet(name: '2025 Aspire DW') do |ws|
      ws.add_row ['Champion Topeka Factory Options - ASPIRE HUD DW']
      ws.add_row ['%', 1.55]
      ws.add_row ['Drywall', 'Retail', 'Dealer Cost']
      ws.add_row ["Drywall T/O - Sect <48' Box", 7463.25, 4815]
      ws.add_row ['Laminate Backsplash - Kit', 100.75, 65]
      ws.add_row ['Ceramic Tile Backsplash - Kit', 325.5, 210]
      ws.add_row ['Desert Springs', 'STD', 'Std']
    end
    pkg.workbook.add_worksheet(name: 'Gold Star II - HUD') do |ws|
      ws.add_row ['DISREGAURD FOR NOW 10.2.2020']
      ws.add_row ['Add Idler Axle', 1475.6, 952]
    end
    pkg.workbook.add_worksheet(name: 'Master Option List') do |ws|
      ws.add_row ['Option No.', 'Description', 'Similar Options', 'PRICE', 'FACTORY $']
      ws.add_row ['MARK UP', 1.55]
      ws.add_row ['OP802270', 'White Wrapped Profile Trim Cove', nil, 1449.25, 935]
      ws.add_row ['OP802270', 'White Wrapped Profile Trim Cove (dup)', nil, 1449.25, 935]
      ws.add_row ['OP020035', 'Laminate Backsplash Kit', nil, 100.75, 65]
    end
    pkg.to_stream.read
  end

  describe Catalog::PriceBooks::Ingest do
    it 'unpacks a ZIP into the private bucket, skipping Mac junk and files already in the book' do
      zip = Zip::OutputStream.write_buffer do |z|
        z.put_next_entry('Pricing/Aspire Net.pdf'); z.write(price_list_pdf)
        z.put_next_entry('Pricing/Factory Options.xlsx'); z.write(workbook)
        z.put_next_entry('__MACOSX/Pricing/._Aspire Net.pdf'); z.write('junk')
      end.string

      result = described_class.new(book).call([upload('Pricing & Options.zip', zip, 'application/zip')])
      expect(result.added.map(&:filename)).to contain_exactly('Aspire Net.pdf', 'Factory Options.xlsx')
      expect(result.added.map(&:kind)).to contain_exactly('price_list', 'order_form')
      expect(result.added.map(&:storage_bucket).uniq).to eq(['dt-private-test'])
      expect(s3.api_requests.select { |r| r[:operation_name] == :put_object }.map { |r| r[:params][:bucket] }.uniq)
        .to eq(['dt-private-test'])

      again = described_class.new(book).call([upload('Aspire Net.pdf', price_list_pdf, 'application/pdf')])
      expect(again.added).to be_empty
      expect(again.duplicates.map(&:filename)).to eq(['Aspire Net.pdf'])
    end
  end

  describe Catalog::PriceBooks::ClaudeClient do
    it 'turns an out-of-credits refusal into something an admin can act on' do
      stub_const('ENV', ENV.to_h.merge('ANTHROPIC_API_KEY' => 'test-key'))
      body = { type: 'error', error: { type: 'invalid_request_error', message: 'Your credit balance is too low to access the Anthropic API.' } }.to_json
      allow_any_instance_of(described_class).to receive(:post).and_return(instance_double(Net::HTTPResponse, code: '400', body: body))
      expect { described_class.call(content: [], tool: Catalog::PriceBooks::Tools::CLASSIFY, system: '') }
        .to raise_error(described_class::Error, 'The Anthropic account is out of credits. Add credits, then choose Read again.')
    end
  end

  describe Catalog::PriceBooks::Classifier do
    it 'reads a page of model numbers as a price list even when its notes mention standards' do
      pdf = Prawn::Document.new do |d|
        d.text 'DUTCH HOUSING ASPIRE MODULAR'
        %w[2840M32024 2842M32388 2844M32169].each { |m| d.text "#{m}  28' x 44'  3  2  $51,395" }
        d.text 'Modular Standards: R-40 Roof Insulation, 2x6 Exterior Walls'
      end.render
      expect(described_class.guess('2026 Aspire MODULAR.pdf', pdf)).to eq('price_list')
    end
  end

  describe Catalog::PriceBooks::TabInventory do
    it 'pre-unticks disregard tabs and the older year of a repeated form, taking the year from the header' do
      pkg = Axlsx::Package.new
      pkg.workbook.add_worksheet(name: 'DGAE - HUD') { |ws| ws.add_row(['2022 DGAE HUD']); ws.add_row(['Drywall', 100, 155]) }
      pkg.workbook.add_worksheet(name: '2023 DGAE HUD') { |ws| ws.add_row(['CHAMPION TOPEKA OPTIONS - DGAE']); ws.add_row(['Drywall', 110, 170]) }
      pkg.workbook.add_worksheet(name: 'Gold Star II - HUD') { |ws| ws.add_row(['DISREGAURD FOR NOW 10.2.2020']); ws.add_row(['Axle', 952, 1475]) }
      pkg.workbook.add_worksheet(name: '2025 Aspire DW') { |ws| ws.add_row(['%', 1.55]); ws.add_row(['Drywall', 4815, 7463]) }
      tabs = described_class.for_bytes('Factory Options.xlsx', pkg.to_stream.read).index_by { |t| t['name'] }

      expect(tabs['DGAE - HUD']).to include('year' => 2022, 'suggest_skip' => true)
      expect(tabs['DGAE - HUD']['reason']).to include('2023 DGAE HUD')
      expect(tabs['2023 DGAE HUD']).to include('year' => 2023, 'suggest_skip' => false)
      expect(tabs['Gold Star II - HUD']).to include('suggest_skip' => true, 'reason' => 'marked to disregard')
      expect(tabs['2025 Aspire DW']['suggest_skip']).to be(false)
      expect(described_class.default_selection(tabs.values)).to contain_exactly('2023 DGAE HUD', '2025 Aspire DW')
    end
  end

  describe Catalog::PriceBooks::PdfExtractor do
    it 'asks again for model numbers on the page it missed, and flags a sheet that contradicts its codes' do
      doc = Catalog::PriceBooks::Ingest.new(book).call([upload('Aspire Net.pdf', price_list_pdf, 'application/pdf')]).added.first
      claude = FakeClaude.new(
        'record_price_list' => [
          { plant: 'DUTCH HOUSING', series: 'ASPIRE HUD', rows: [
            { model_number: '2856H32392', model_name: 'Belvidere', box_width_ft: 28, box_length_ft: 56, beds: 3, baths: 2, net_base_price: 57_995 }
          ] },
          ->(content) {
            expect(content.last[:text]).to include('3260H32181')
            { rows: [{ model_number: '3260H32181', model_name: "60' Shelby", box_width_ft: 30, box_length_ft: 60,
                       beds: 3, baths: 2, net_base_price: 67_395 }] }
          }
        ]
      )
      recorder = Catalog::PriceBooks::Recorder.new(book, client: claude)
      described_class.new(doc, price_list_pdf, recorder).call

      items = book.import_items.where(item_type: 'variant_price').index_by { |i| i.payload['model_number'] }
      expect(items.keys).to contain_exactly('2856H32392', '3260H32181')
      expect(items['3260H32181'].flags).to include('model_code_width_mismatch')
      expect(items['2856H32392'].flags).to be_empty
      expect(doc.reload.metadata['missing_model_numbers']).to eq([])
      expect(recorder.usage['calls']).to eq(2)
    end
  end

  describe Catalog::PriceBooks::WorkbookExtractor do
    let(:doc) { Catalog::PriceBooks::Ingest.new(book).call([upload('Factory Options.xlsx', workbook)]).added.first }

    it 'reads only the tabs left ticked' do
      doc.update!(metadata: doc.metadata.merge('selected_tabs' => ['Master Option List']))
      claude = FakeClaude.new({})
      described_class.new(doc, workbook, Catalog::PriceBooks::Recorder.new(book, client: claude)).call

      expect(claude.calls).to be_empty
      expect(doc.reload.metadata.dig('tabs', '2025 Aspire DW')).to eq('kind' => 'skipped', 'reason' => 'not selected')
      expect(book.import_items.pluck(:item_type).uniq).to eq(['option'])
    end

    it 'grounds every price in its cell, fixes swapped columns, repairs missed cells, skips stale tabs, reads the master list directly' do
      # Every tab ticked, so the model's own stale check is exercised too.
      doc.update!(metadata: doc.metadata.merge('selected_tabs' => doc.metadata['tab_list'].map { |t| t['name'] }))
      claude = FakeClaude.new(
        'record_options' => [
          # Aspire DW, first pass: one option read with cost and retail swapped,
          # one with a number that is not in its cell, one row missed entirely.
          { markup_multiplier: 1.55, options: [
            { section: 'Drywall', description: "Drywall T/O - Sect <48' Box", dealer_cost: 7463.25, dealer_cost_cell: 'B4',
              retail: 4815, retail_cell: 'C4', applies_to: { box_length_max_ft: 47 } },
            { section: 'Backsplash', description: 'Laminate Backsplash - Kit', dealer_cost: 66, dealer_cost_cell: 'C5',
              retail: 100.75, retail_cell: 'B5' },
            { section: 'Countertop', description: 'Desert Springs', is_standard: true, dealer_cost_cell: 'C7', retail_cell: 'B7' }
          ] },
          # Repair pass for B6/C6
          { options: [{ section: 'Backsplash', description: 'Ceramic Tile Backsplash - Kit', dealer_cost: 210,
                        dealer_cost_cell: 'C6', retail: 325.5, retail_cell: 'B6' }] },
          # Gold Star II: stale
          { markup_multiplier: 1.55, stale: { is_stale: true, reason: 'DISREGAURD FOR NOW' }, options: [] }
        ]
      )
      described_class.new(doc, workbook, Catalog::PriceBooks::Recorder.new(book, client: claude)).call

      prices = book.import_items.where(item_type: 'option_price').index_by { |i| i.payload['description'] }
      drywall = prices["Drywall T/O - Sect <48' Box"]
      expect(drywall.payload.values_at('dealer_cost', 'suggested_retail')).to eq([4815.0, 7463.25])
      expect(drywall.flags).to include('cost_retail_swapped')

      laminate = prices['Laminate Backsplash - Kit']
      expect(laminate.payload['dealer_cost']).to eq(65.0)
      expect(laminate.flags).to include('cost_cell_differs')

      expect(prices['Ceramic Tile Backsplash - Kit'].flags).to include('label_needs_review')
      expect(prices['Desert Springs']).to have_attributes(flags: [])
      expect(prices['Desert Springs'].payload['is_standard']).to be(true)
      expect(doc.reload.metadata.dig('tabs', '2025 Aspire DW', 'uncovered_cells')).to eq([])
      expect(doc.metadata.dig('tabs', 'Gold Star II - HUD')).to include('stale' => true)
      expect(book.import_items.where("payload->>'tab' = 'Gold Star II - HUD'")).to be_empty

      coded = book.import_items.where(item_type: 'option').order(:id).select { |i| i.payload['kind'] == 'coded' }
      expect(coded.map { |i| i.payload['factory_code'] }).to eq(%w[OP802270 OP802270 OP020035])
      expect(coded.first.flags).to include('duplicate_factory_code')
      expect(coded.last.payload.values_at('dealer_cost', 'suggested_retail')).to eq([65.0, 100.75])
      expect(claude.calls.map { |c| c[:tool] }).to eq(%w[record_options record_options record_options])
    end
  end

  describe 'reconcile and publish' do
    def variant_item(book, number, price, name: 'Belvidere', status: 'approved')
      book.import_items.create!(item_type: 'variant_price', review_status: status, payload: {
        'model_number' => number, 'model_name' => name, 'series' => 'ASPIRE HUD', 'plant' => 'DUTCH HOUSING',
        'building_code' => 'HUD', 'width_ft' => 28, 'length_ft' => 56, 'beds' => 3, 'baths' => 2, 'net_base_price' => price
      })
    end

    it 'publishes approved items into the catalog, then compares the next book against it' do
      variant_item(book, '2856H32392', 57_995)
      book.import_items.create!(item_type: 'option_price', review_status: 'approved', payload: {
        'tab' => '2025 Aspire DW', 'section' => 'Drywall', 'description' => "Drywall T/O - Sect <48' Box",
        'dealer_cost' => 4815, 'suggested_retail' => 7463.25, 'applies_to' => { 'box_length_max_ft' => 47 }
      })
      book.import_items.create!(item_type: 'standard_feature', review_status: 'approved',
                                payload: { 'category' => 'Kitchen', 'name' => 'Wrapped Shaker Cabinets', 'series' => 'Aspire' })
      Catalog::PriceBooks::Reconciler.new(book).call
      expect(book.import_items.find_by(item_type: 'option_price').payload['applies_to']['section_type']).to eq('multi')

      counts = Catalog::PriceBooks::Publisher.new(book, by: admin).call
      expect(counts).to include('variant_prices' => 1, 'option_prices' => 1, 'standard_features' => 1)
      expect(book.reload.status).to eq('published')

      variant = CatalogPlanVariant.find_by!(manufacturer: mfr, model_number: '2856H32392')
      expect(variant.catalog_plan).to have_attributes(name: 'Belvidere', series: 'Aspire')
      expect(variant.variant_prices.first.net_base_price).to eq(57_995)
      price = CatalogOptionPrice.find_by!(price_book: book)
      expect(price).to have_attributes(dealer_cost: 4815, section_type: 'multi', max_length_ft: 47)

      nxt = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027', created_by: admin)
      variant_item(nxt, '2856H32392', 59_000, status: 'pending')
      Catalog::PriceBooks::Reconciler.new(nxt).call
      changed = nxt.import_items.find_by(item_type: 'variant_price', change_type: 'changed')
      expect(changed.previous_values).to eq('net_base_price' => 57_995.0)
      expect(changed.matched).to eq(variant)

      expect { Catalog::PriceBooks::Publisher.new(nxt, by: admin).call }
        .to raise_error(Catalog::PriceBooks::Publisher::NotReady, /1 items still need review/)
    end

    it 'works out a missing cost from retail and the markup, and lists rows it cannot price' do
      variant_item(book, '2856H32392', 57_995)
      retail_only = book.import_items.create!(item_type: 'option_price', review_status: 'approved', payload: {
        'tab' => '2025 Aspire DW', 'section' => 'Windows', 'description' => '30 x 42 Picture Window',
        'suggested_retail' => 325.5, 'markup' => 1.55
      })
      blank = book.import_items.create!(item_type: 'option_price', review_status: 'approved', payload: {
        'tab' => 'DGAE - HUD', 'section' => 'Windows', 'description' => 'Bay Window', 'suggested_retail' => 0.0, 'markup' => 1.55
      })

      expect { Catalog::PriceBooks::Publisher.new(book, by: admin).call }
        .to raise_error(Catalog::PriceBooks::Publisher::NotReady, /1 approved rows have no price: Bay Window \(DGAE - HUD\)/)
      expect(book.reload.status).not_to eq('published')

      blank.update!(review_status: 'rejected')
      Catalog::PriceBooks::Publisher.new(book, by: admin).call
      expect(retail_only.reload.payload['dealer_cost']).to eq(210.0)
      expect(CatalogOptionPrice.find_by!(price_book: book).dealer_cost).to eq(210)
    end

    it 'keeps two series that share a model number apart' do
      # Champion prices 2848M32160 as the Aspire 48' Lancaster and as a Genesis ranch.
      aspire = variant_item(book, '2848M32160', 54_695, name: "48' Lancaster")
      genesis = book.import_items.create!(item_type: 'variant_price', review_status: 'approved', payload: {
        'model_number' => '2848M32160', 'series' => 'Genesis', 'plant' => 'Champion Genesis', 'building_code' => 'MOD',
        'width_ft' => 28, 'length_ft' => 48, 'beds' => 3, 'baths' => 2, 'home_type' => 'RANCH', 'net_base_price' => 81_645
      })
      Catalog::PriceBooks::Reconciler.new(book).call
      expect([aspire, genesis].map { |i| i.reload.payload['plan_series'] }).to eq(%w[Aspire Genesis])

      Catalog::PriceBooks::Publisher.new(book, by: admin).call
      variants = CatalogPlanVariant.where(manufacturer: mfr, model_number: '2848M32160').index_by(&:series)
      expect(variants.keys).to contain_exactly('Aspire', 'Genesis')
      expect(variants['Aspire'].variant_prices.first.net_base_price).to eq(54_695)
      expect(variants['Genesis'].variant_prices.first.net_base_price).to eq(81_645)
    end

    it 'turns a model missing from the new book into a removal to confirm' do
      variant_item(book, '2856H32392', 57_995)
      Catalog::PriceBooks::Publisher.new(book, by: admin).call

      nxt = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027', created_by: admin)
      variant_item(nxt, '2860H32047', 60_195, name: "60' Woodward")
      Catalog::PriceBooks::Reconciler.new(nxt).call
      removed = nxt.import_items.find_by(change_type: 'removed')
      expect(removed.payload['model_number']).to eq('2856H32392')
      expect(removed.flags).to eq(['missing_from_new_book'])

      removed.update!(review_status: 'approved')
      Catalog::PriceBooks::Publisher.new(nxt, by: admin).call
      expect(CatalogPlanVariant.find_by(model_number: '2856H32392').status).to eq('discontinued')
      expect(book.reload.status).to eq('superseded')
    end
  end

  describe Catalog::PriceBooks::CatalogLink do
    it 'links rows by the model number in image names only when the names agree' do
      belvidere = book.import_items.create!(item_type: 'variant_price', payload: { 'model_number' => '2856H32392', 'plan_name' => 'Belvidere' })
      easton = book.import_items.create!(item_type: 'variant_price', payload: { 'model_number' => '2856H32301', 'plan_name' => 'Easton' })
      models = [
        { 'id' => 'g-belv', 'champion_model_id' => 'g-belv', 'slug' => 'aspire-belvidere', 'name' => 'Aspire Belvidere',
          'text' => 'https://s7d9.scene7.com/is/image/championhomes/Paramount 2856M32392 Kitchen 3' },
        # Champion filed Easton's photos under Belvidere's number.
        { 'id' => 'g-east', 'champion_model_id' => 'g-east', 'slug' => 'aspire-easton', 'name' => 'Aspire Easton',
          'text' => 'https://s7d9.scene7.com/is/image/championhomes/Paramount 2856H32392 Kitchen 3' }
      ]
      result = described_class.new(book, models: models, label: 'Champion catalog: dutch-housing').call

      expect(belvidere.reload.payload['external']).to include('champion_model_id' => 'g-belv')
      expect(easton.reload.payload['external']).to be_nil
      expect(result).to include('linked' => 1, 'source' => 'Champion catalog: dutch-housing')
      expect(result['models_without_row'].map { |m| m['slug'] }).to eq(['aspire-easton'])
      expect(book.reload.metadata['catalog_links'].size).to eq(1)
    end

    it 'links the loaded homes themselves when the book is published' do
      dealer = Company.create!(name: "Dealer #{SecureRandom.hex(3)}")
      home = dealer.vehicles.create!(make: 'Champion', model: 'Aspire Belvidere', year: 2026, source: 'champion_ims',
                                     serial_number: "S#{SecureRandom.hex(4)}", vin: "V#{SecureRandom.hex(6)}",
                                     champion_model_id: 'g-belv',
                                     champion_raw_payload: { 'images' => [{ 'path' => '.../Aspire 2856H32392 Kitchen 1' }] })
      book.import_items.create!(item_type: 'variant_price', review_status: 'approved', payload: {
        'model_number' => '2856H32392', 'plan_name' => 'Belvidere', 'plan_series' => 'Aspire', 'building_code' => 'HUD', 'net_base_price' => 57_995
      })

      row = Catalog::PriceBooks::LinkSources.loaded.find { |r| r[:key] == "ims:#{dealer.id}" }
      expect(row).to include(homes: 1)
      described_class.new(book, models: Catalog::PriceBooks::LinkSources.loaded_models(row[:key]), label: row[:label]).call
      Catalog::PriceBooks::Publisher.new(book, by: admin).call

      variant = CatalogPlanVariant.find_by!(manufacturer: mfr, model_number: '2856H32392')
      expect(variant.external_ids).to include('champion_model_id' => 'g-belv', 'vehicle_ids' => [home.id])
      expect(home.reload.catalog_plan_variant_id).to eq(variant.id)
    end
  end
end
