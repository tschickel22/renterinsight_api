# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Admin::CatalogSwatches', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:decatur) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }

  def headers_for(role)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S',
                        password: 'Pass1234!', company_id: company.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def swatch(set, name, factory: nil, hex: '#686155')
    CatalogSwatch.create!(manufacturer: mfr, factory: factory, set_name: set, name: name, hex: hex, image_url: "https://b/#{SecureRandom.hex(4)}.jpg")
  end

  describe 'matching a finish to its sample' do
    def find(surface, value, factory: nil) = CatalogSwatch.for_finish(manufacturer_id: mfr.id, factory_id: factory&.id, surface: surface, value: value)

    it 'ignores caption words and prefers the plant sheet' do
      general = swatch('Wall Board Colors', 'Casper Cashmere Main Panel')
      expect(find('Accent wall', 'Casper Cashmere')).to eq(general)
      chai = swatch('Cabinets', 'Chai Oak Shaker Door', factory: decatur)
      expect(find('Cabinets', 'Chai Oak', factory: decatur)).to eq(chai)
      expect(find('Cabinets', 'Chai Oak', factory: topeka)).to be_nil
    end

    it 'sees a tile name through the catalog wording, but never a lone word inside a longer name' do
      inhale = swatch('Ceramic Tile', 'Inhale Gris 4 x 12')
      swatch('Shutters', 'White')
      expect(find('Backsplash', '1 Row Ceramic Inhale Gris')).to eq(inhale)
      expect(find('Backsplash', '1 Row Inhale Gris (ceramic)')).to eq(inhale)
      expect(find('Backsplash', '1 Row Sunset Falls White (ceramic)')).to be_nil
    end

    it 'uses the surface when a name sits in several sets, and gives up on a tie' do
      siding = swatch('Standard Vinyl Siding', 'White')
      shutter = swatch('Shutters', 'White')
      expect(find('Siding', 'White')).to eq(siding)
      expect(find('Shutters', 'White')).to eq(shutter)
      expect(find('Trim', 'White')).to be_nil
    end
  end

  describe 'upload and read' do
    it 'stores the sheet privately and reads it in the background' do
      allow(PrivateFiles).to receive(:put).and_return('private://bucket/catalog/swatch-sheets/x.pdf')
      file = Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4'), 'application/pdf', original_filename: 'poster.pdf')
      expect do
        post '/api/admin/catalog_swatches/upload', headers: headers_for('platform_admin'),
                                                   params: { manufacturer_id: mfr.id, factory_id: decatur.id, file: file }
      end.to have_enqueued_job(CatalogSwatchSheetJob)
      expect(response).to have_http_status(:created)
      expect(CatalogSwatchSheet.last).to have_attributes(factory_id: decatur.id, filename: 'poster.pdf', status: 'queued')
    end

    it 'deletes a sheet with its samples, so it can be uploaded to the right plant' do
      sheet = CatalogSwatchSheet.create!(manufacturer: mfr, filename: 'prime.pdf', storage_ref: 'private://b/p.pdf', status: 'done')
      swatch('Cabinets', 'Chai Oak').update!(catalog_swatch_sheet: sheet)
      keep = swatch('Shutters', 'Black')
      delete "/api/admin/catalog_swatches/sheets/#{sheet.id}", headers: headers_for('platform_admin')
      expect(response).to have_http_status(:no_content)
      expect(CatalogSwatch.where(manufacturer: mfr)).to eq([keep])
    end

    it 'is for platform admins only' do
      get '/api/admin/catalog_swatches', headers: headers_for('sales'), params: { manufacturer_id: mfr.id }
      expect(response).to have_http_status(:forbidden)
    end

    it 'saves each sample, and reading the sheet again updates rather than duplicates' do
      sheet = CatalogSwatchSheet.create!(manufacturer: mfr, filename: 'poster.pdf', storage_ref: 'private://b/k.pdf')
      image = (Vips::Image.black(40, 40, bands: 3) + [104, 97, 85]).cast(:uchar)
      reader = instance_double(Catalog::Swatches::SheetReader, call: {
        swatches: [{ set: 'Shaker Style Cabinets', name: 'Timberwolf', note: nil, page: 1, image: image, hex: '#686155' }],
        missed: [{ set: 'Ceramic Tile', name: 'Catch Ice' }], cost_usd: 0.03
      })
      allow(PrivateFiles).to receive(:read).and_return('%PDF')
      allow(Catalog::Swatches::SheetReader).to receive(:new).and_return(reader)
      s3 = instance_double(S3UploadService, s3_client: double(put_object: true), bucket_name: 'bucket', region: 'us-west-2')
      allow(S3UploadService).to receive(:new).and_return(s3)

      2.times { CatalogSwatchSheetJob.perform_now(sheet.id) }
      expect(sheet.reload).to have_attributes(status: 'done', swatch_count: 1, missed: [{ 'set' => 'Ceramic Tile', 'name' => 'Catch Ice' }])
      expect(CatalogSwatch.where(manufacturer: mfr).pluck(:name, :hex)).to eq([%w[Timberwolf #686155]])
    end
  end

  it 'lets TrueView show the model the sample' do
    sample = swatch('Shaker Style Cabinets', 'Timberwolf')
    prompt = Truebuild::Trueview.prompt(room: 'kitchen', selection: [{ 'surface' => 'Cabinets', 'value' => 'Timberwolf' }], swatches: [sample])
    expect(prompt).to include('exactly as in sample image 2 (color #686155)', 'flat samples of the actual finishes')
  end
end
