# frozen_string_literal: true

module ImportExport
  # One value made safe for a CSV a person will open in Excel or Sheets.
  #
  # A cell that starts with =, +, -, @ (or a tab or carriage return) opens as
  # a formula, so a lead named "=HYPERLINK(...)" typed into a web form would
  # run on the dealer's computer. Such text gets a leading apostrophe, which
  # the spreadsheet shows as plain text. Real numbers (-500, +1.5) are left
  # alone so they still add up.
  module CsvCell
    FORMULA_START = /\A[=+\-@\t\r]/
    NUMBER = /\A[+-]?\d[\d,]*(\.\d+)?\z/

    module_function

    def safe(value)
      return value unless value.is_a?(String)
      return value unless value.match?(FORMULA_START)
      return value if value.match?(NUMBER)

      "'#{value}"
    end
  end
end
