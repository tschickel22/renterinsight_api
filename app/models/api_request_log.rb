# frozen_string_literal: true

# One row per Partner API request. Written by ApiKeyAuthentication, and read
# back by it as the hourly rate-limit counter (the table is shared by every
# instance, which Rails.cache in production is not).
#
# Path only, never the query string: search params carry lead names, emails
# and phone numbers.
class ApiRequestLog < ApplicationRecord
  belongs_to :api_key, optional: true
  belongs_to :company, optional: true
end
