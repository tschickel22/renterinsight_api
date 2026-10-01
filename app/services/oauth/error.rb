# frozen_string_literal: true

module Oauth
  # An OAuth error response (RFC 6749 section 5.2 / 4.1.2.1).
  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, description = nil, status: 400)
      @code = code
      @status = status
      super(description || code)
    end

    def as_json(*)
      { error: code, error_description: message }
    end
  end
end
