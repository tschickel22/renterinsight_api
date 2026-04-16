require 'net/http'
require 'uri'
require 'resolv'
require 'ipaddr'
require 'json'

module WorkflowEngine
  module StepExecutors
    class CallWebhook < Base
      PRIVATE_CIDRS = [
        IPAddr.new('10.0.0.0/8'),
        IPAddr.new('172.16.0.0/12'),
        IPAddr.new('192.168.0.0/16'),
        IPAddr.new('127.0.0.0/8'),
        IPAddr.new('169.254.0.0/16'),
        IPAddr.new('::1'),
        IPAddr.new('fc00::/7')
      ].freeze

      def call
        cfg = @step['config'] || {}
        url = WorkflowEngine::VariableResolver.resolve(cfg['url'].to_s, @run.variables)
        method = (cfg['method'] || 'POST').to_s.upcase
        headers = (cfg['headers'] || {}).each_with_object({}) { |(k, v), h| h[k] = WorkflowEngine::VariableResolver.resolve(v.to_s, @run.variables) }
        body = cfg['body']
        body = WorkflowEngine::VariableResolver.resolve(body, @run.variables) if body.is_a?(String)
        body = WorkflowEngine::VariableResolver.resolve_hash(body, @run.variables) if body.is_a?(Hash)

        begin
          uri = URI.parse(url)
        rescue URI::InvalidURIError => e
          return failed("invalid_url: #{e.message}")
        end
        return failed('invalid_scheme') unless %w[http https].include?(uri.scheme)
        return failed('missing_host') if uri.host.blank?

        begin
          ip_str = Resolv.getaddress(uri.host)
          ip = IPAddr.new(ip_str)
        rescue => e
          return failed("dns_failure: #{e.message}")
        end
        return failed('private_ip_blocked') if private_ip?(ip)

        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          http.open_timeout = 5
          http.read_timeout = 10
          req_class = case method
                      when 'GET' then Net::HTTP::Get
                      when 'PUT' then Net::HTTP::Put
                      when 'DELETE' then Net::HTTP::Delete
                      when 'PATCH' then Net::HTTP::Patch
                      else Net::HTTP::Post
                      end
          req = req_class.new(uri.request_uri)
          headers.each { |k, v| req[k] = v }
          if body.is_a?(Hash)
            req['Content-Type'] ||= 'application/json'
            req.body = body.to_json
          elsif body.is_a?(String) && !body.empty?
            req.body = body
          end
          res = http.request(req)
          code = res.code.to_i
          snippet = res.body.to_s[0..2000]
          if (200..299).cover?(code)
            { status: 'success', output: { status: code, body: snippet }, next_step_id: next_step_from_edges, wait: nil, error: {} }
          else
            { status: 'failed', output: { status: code, body: snippet }, next_step_id: nil, wait: nil, error: { message: "http_#{code}" } }
          end
        rescue => e
          failed("request_error: #{e.message}")
        end
      end

      private

      def private_ip?(ip)
        PRIVATE_CIDRS.any? { |cidr| cidr.include?(ip) }
      rescue
        true
      end

      def failed(msg)
        { status: 'failed', output: {}, next_step_id: nil, wait: nil, error: { message: msg } }
      end
    end
  end
end
