# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportExport::CsvParser, 'workbook tabs' do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, 'prospects.xlsx')
      pkg = Axlsx::Package.new
      pkg.workbook.add_worksheet(name: 'Notes') { |ws| ws.add_row(['Read me first']) }
      pkg.workbook.add_worksheet(name: 'Prospects') do |ws|
        ws.add_row(%w[Name Email])
        ws.add_row(['Ada', 'ada@example.com'])
      end
      pkg.workbook.add_worksheet(name: 'Blank')
      pkg.serialize(@path)
      example.run
    end
  end

  it 'reads the first tab by default and lists every tab' do
    parsed = described_class.new(@path).parse
    expect(parsed[:sheets]).to eq(%w[Notes Prospects Blank])
    expect(parsed[:sheet]).to eq('Notes')
    expect(parsed[:headers]).to eq(['Read me first'])
  end

  it 'reads the tab it is given' do
    parsed = described_class.new(@path, sheet: 'Prospects').parse
    expect(parsed[:sheet]).to eq('Prospects')
    expect(parsed[:headers]).to eq(%w[Name Email])
    expect(parsed[:rows]).to eq([['Ada', 'ada@example.com']])
  end

  it 'returns no rows for an empty tab' do
    parsed = described_class.new(@path, sheet: 'Blank').parse
    expect(parsed).to include(headers: [], rows: [], total_rows: 0)
  end

  it 'refuses a tab the file does not have' do
    expect { described_class.new(@path, sheet: 'Nope').parse }
      .to raise_error(ImportExport::CsvParser::ParseError, 'This file has no tab named "Nope"')
  end
end
