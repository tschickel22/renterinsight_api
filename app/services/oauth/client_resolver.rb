# frozen_string_literal: true

require 'net/http'

module Oauth
  # Turns a client_id from an authorization or token request into an
  # OauthClient.
  #
  # Two kinds:
  # - an id we issued through dynamic client registration ("dtc_..."), and
  # - an HTTPS URL, which is a Client ID Metadata Document: the app publishes
  #   its own name and redirect URIs at that URL and we fetch them. This is the
  #   MCP spec's preferred registration since 2025-11-25 and what ChatGPT uses
  #   when it can.
  #
  # Metadata documents are only fetched from the same hosts redirects are
  # allowed to (see RedirectPolicy), which also keeps this from being a way to
  # make our server request arbitrary URLs. No redirects, small body, short
  # timeout. A fetched document is kept for a day.
  module ClientResolver
    REFETCH_AFTER = 24.hours
    MAX_BYTES = 64.kilobytes
    TIMEOUT = 5

    module_function

    def find!(client_id)
      raise Error.new('invalid_client', 'client_id is required', status: 401) if client_id.blank?

      if client_id.to_s.start_with?('https://')
        metadata_document_client!(client_id.to_s)
      else
        OauthClient.find_by(client_id: client_id.to_s, registration_type: 'dcr') ||
          raise(Error.new('invalid_client', 'Unknown client', status: 401))
      end
    end

    def metadata_document_client!(url)
      existing = OauthClient.find_by(client_id: url)
      return existing if existing && existing.metadata_fetched_at && existing.metadata_fetched_at > REFETCH_AFTER.ago

      doc = fetch_document(url)
      client = existing || OauthClient.new(client_id: url, registration_type: 'cimd')
      client.assign_attributes(
        client_name: doc['client_name'].presence || URI.parse(url).host,
        redirect_uris: Array(doc['redirect_uris']).map(&:to_s),
        client_uri: doc['client_uri'],
        logo_uri: doc['logo_uri'],
        metadata: doc.slice('client_name', 'client_uri', 'logo_uri', 'grant_types', 'response_types',
                            'token_endpoint_auth_method', 'token_endpoint_auth_methods_supported'),
        metadata_fetched_at: Time.current
      )
      raise Error.new('invalid_client', client.errors.full_messages.to_sentence, status: 401) unless client.save

      client
    end

    def fetch_document(url)
      uri = URI.parse(url)
      unless uri.scheme == 'https' && uri.path.present? && uri.path != '/' && RedirectPolicy.allowed_host?(uri.host)
        raise Error.new('invalid_client', 'That client metadata URL is not on an allowed host', status: 401)
      end

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri, 'Accept' => 'application/json'))
      end
      unless response.is_a?(Net::HTTPSuccess) && response.body.to_s.bytesize <= MAX_BYTES
        raise Error.new('invalid_client', 'Could not read the client metadata document', status: 401)
      end

      doc = JSON.parse(response.body)
      unless doc.is_a?(Hash) && doc['client_id'] == url
        raise Error.new('invalid_client', 'Client metadata document does not name itself', status: 401)
      end

      doc
    rescue URI::InvalidURIError, JSON::ParserError, SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("[Oauth::ClientResolver] metadata fetch failed for #{url}: #{e.class}")
      raise Error.new('invalid_client', 'Could not read the client metadata document', status: 401)
    end
  end
end
