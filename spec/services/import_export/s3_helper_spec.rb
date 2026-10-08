# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportExport::S3Helper do
  let(:key) { 'private://bucket/imports/1/prospects.csv' }

  before do
    allow(PrivateFiles).to receive(:locate).with(key).and_return(['bucket', 'imports/1/prospects.csv'])
    allow(PrivateFiles).to receive(:read).with(key).and_return("Name,Email\nAda,ada@example.com\n")
  end

  it 'keeps the download on disk through a GC inside the block, then removes it' do
    seen = nil
    parsed = described_class.with_local_file(key) do |path|
      seen = path
      GC.start(full_mark: true, immediate_sweep: true)
      expect(File.exist?(path)).to be(true)
      ImportExport::CsvParser.new(path).parse
    end

    expect(File.extname(seen)).to eq('.csv')
    expect(parsed[:rows]).to eq([['Ada', 'ada@example.com']])
    expect(File.exist?(seen)).to be(false)
  end

  it 'yields a path that is already local as is' do
    Tempfile.create(['local', '.csv']) do |f|
      expect(described_class.with_local_file(f.path) { |path| path }).to eq(f.path)
      expect(File.exist?(f.path)).to be(true)
    end
  end

  it 'yields nil for a blank key' do
    expect(described_class.with_local_file(nil) { |path| path }).to be_nil
  end
end
