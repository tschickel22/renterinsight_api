# frozen_string_literal: true

module Truebuild
  # The address of a home's hosted designer page, for a dealer whose own
  # website lists our inventory through the public API (Factory Direct puts
  # it behind their Design this home buttons). One shared host for every
  # dealer: TRUEBUILD_DESIGN_HOST (design.mydealertide.com, through the
  # Cloudflare Worker like dealer sites). Until that host is routed, the page
  # answers on the API's own address under /design.
  #
  #   https://design.mydealertide.com/<dealer>/<home id>
  #   https://api.dealertide.com/design/<dealer>/<home id>
  #
  # <dealer> is the company's subdomain, or its public inventory token (already
  # public: it is in every page that embeds the inventory).
  module DesignLink
    module_function

    def host = ENV['TRUEBUILD_DESIGN_HOST'].presence&.downcase

    def url(company, vehicle)
      key = dealer_key(company)
      return nil if key.blank? || vehicle.nil?

      if host
        "https://#{host}/#{key}/#{vehicle.id}"
      else
        "#{(ENV['RAILS_API_URL'].presence || 'http://localhost:3001').chomp('/')}/design/#{key}/#{vehicle.id}"
      end
    end

    def dealer_key(company) = company.subdomain.presence || company.public_inventory_token

    def company_for(key)
      return nil if key.blank?

      Company.find_by(subdomain: key) || Company.find_by(public_inventory_token: key)
    end
  end
end
