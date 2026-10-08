# frozen_string_literal: true

require 'csv'
require 'roo'

module ImportExport
  # Parses CSV and Excel files into a uniform { headers:, rows:, total_rows: } shape.
  # Strips UTF-8 BOM and tolerates Windows-1252 encoded CSVs.
  # Workbooks read the named sheet (the first one when none is given) and also
  # return every sheet name as `sheets:` plus the one read as `sheet:`, so the
  # import wizard can offer a tab picker. CSVs return `sheets: []`.
  class CsvParser
    class ParseError < StandardError; end

    def initialize(path, sheet: nil)
      @path  = path
      @sheet = sheet.presence
    end

    def parse
      ext = File.extname(@path).downcase
      case ext
      when '.csv', '.txt' then parse_csv
      when '.xlsx', '.xls', '.ods' then parse_spreadsheet(ext)
      else raise ParseError, "Unsupported file type: #{ext}"
      end
    end

    private

    def parse_csv
      raw = File.binread(@path)
      raw.sub!("\xEF\xBB\xBF".b, '') # strip UTF-8 BOM
      text = raw.force_encoding('UTF-8')
      unless text.valid_encoding?
        text = raw.force_encoding('Windows-1252').encode('UTF-8', invalid: :replace, undef: :replace)
      end

      table = CSV.parse(text, headers: true, skip_blanks: true, liberal_parsing: true)
      headers = table.headers.compact.map { |h| h.to_s.strip }
      rows = table.map { |r| headers.map { |h| r[h] } }
      { headers: headers, rows: rows, total_rows: rows.size, sheets: [], sheet: nil }
    rescue CSV::MalformedCSVError => e
      raise ParseError, "Malformed CSV: #{e.message}"
    end

    def parse_spreadsheet(ext)
      klass = case ext
              when '.xlsx' then Roo::Excelx
              when '.xls'  then Roo::Excel
              when '.ods'  then Roo::OpenOffice
              end
      sheet = klass.new(@path)
      sheets = sheet.sheets
      chosen = @sheet || sheets.first
      raise ParseError, "This file has no tab named \"#{chosen}\"" unless sheets.include?(chosen)

      sheet.default_sheet = chosen
      return { headers: [], rows: [], total_rows: 0, sheets: sheets, sheet: chosen } if sheet.first_row.nil?

      headers = sheet.row(1).map { |h| h.to_s.strip }
      rows = []
      ((sheet.first_row + 1)..sheet.last_row).each do |i|
        row = sheet.row(i)
        next if row.all? { |v| v.nil? || v.to_s.strip.empty? }
        rows << headers.each_with_index.map { |_, idx| row[idx] }
      end
      { headers: headers, rows: rows, total_rows: rows.size, sheets: sheets, sheet: chosen }
    rescue ParseError
      raise
    rescue StandardError => e
      raise ParseError, "Failed to parse spreadsheet: #{e.message}"
    end
  end
end
