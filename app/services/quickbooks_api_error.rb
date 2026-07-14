# frozen_string_literal: true

# Base error for anything raised by the QuickBooks integration. Split into
# its own file so Zeitwerk can auto-load the constant — previously all five
# QB error classes lived inside app/services/quickbooks/client.rb, which
# Zeitwerk only expects to define Quickbooks::Client, so the extra classes
# were opaque and `rescue QuickbooksApiError` blew up with an uninitialized-
# constant NameError as soon as anything raised.
class QuickbooksApiError < StandardError
  attr_reader :status_code, :response_body

  def initialize(msg, status_code = nil, response_body = nil)
    super(msg)
    @status_code   = status_code
    @response_body = response_body
  end
end
