# frozen_string_literal: true

require 'csv'
require 'roo'

module ImportExport
  # Parses CSV and Excel files into a uniform { headers:, rows:, total_rows: } shape.
  # Strips UTF-8 BOM and tolerates Windows-1252 encoded CSVs.
  class CsvParser
    class ParseError < StandardError; end

    def initialize(path)
      @path = path
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
      { headers: headers, rows: rows, total_rows: rows.size }
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
      sheet.default_sheet = sheet.sheets.first
      headers = sheet.row(1).map { |h| h.to_s.strip }
      rows = []
      ((sheet.first_row + 1)..sheet.last_row).each do |i|
        row = sheet.row(i)
        next if row.all? { |v| v.nil? || v.to_s.strip.empty? }
        rows << headers.each_with_index.map { |_, idx| row[idx] }
      end
      { headers: headers, rows: rows, total_rows: rows.size }
    rescue StandardError => e
      raise ParseError, "Failed to parse spreadsheet: #{e.message}"
    end
  end
end
