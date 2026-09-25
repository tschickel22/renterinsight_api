# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module SocialBlog
  # PostgREST calls to a marketing site's Supabase with its service key.
  module SupabaseRest
    class Error < StandardError; end

    module_function

    def request(site, method, path, body: nil, prefer: nil)
      uri  = URI("#{site.supabase_url.chomp('/')}/rest/v1/#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30

      req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      req['apikey']        = site.service_key
      req['Authorization'] = "Bearer #{site.service_key}"
      req['Content-Type']  = 'application/json'
      # Plain JSON back. The reply arrived compressed on staging and could not be parsed.
      req['Accept-Encoding'] = 'identity'
      req['Prefer']        = prefer if prefer
      req.body = body.to_json if body

      res = http.request(req)
      raise Error, "Supabase error (#{res.code}): #{res.body.to_s.truncate(300)}" unless res.is_a?(Net::HTTPSuccess)

      # Not .present?: on a body that is not valid UTF-8 that raises before parsing.
      res.body.to_s.empty? ? nil : JSON.parse(res.body)
    rescue JSON::ParserError, ArgumentError, Encoding::CompatibilityError => e
      raise Error, "Supabase sent a reply that could not be read: #{e.message.truncate(120)}"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Supabase timeout: #{e.message}"
    end
  end
end
