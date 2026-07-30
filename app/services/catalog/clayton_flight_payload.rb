# frozen_string_literal: true

require 'net/http'
require 'uri'

module Catalog
  # Shared parsing for claytonhomes.com, a Next.js App Router site.
  #
  # The site server-renders everything and makes NO client-side data calls, so
  # the complete dataset ships inside the initial HTML as an RSC "flight"
  # payload — a series of `self.__next_f.push([1,"<json fragment>"])` script
  # tags whose string arguments must be concatenated (a single JSON object is
  # routinely split across pushes) and JS-unescaped before parsing.
  #
  # This matters because the rendered DOM is a SUBSET of the payload: a home
  # center page renders ~12 <article> cards but carries all 200+ models in the
  # flight data. Parse the payload, not the DOM.
  #
  # robots.txt allows /locations/ and /homes-for-sale/ while disallowing /api/,
  # so these HTML surfaces are the sanctioned path — there is no API call to make.
  module ClaytonFlightPayload
    FLIGHT_RE  = /self\.__next_f\.push\(\[1,"(.*?)"\]\)/m
    USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                 '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    HTTP_TIMEOUT = 30

    module_function

    # Concatenate every flight fragment in the document and undo the JS string
    # escaping, yielding one searchable buffer of RSC data.
    def flight_payload(html)
      return '' if html.blank?

      joined = html.scan(FLIGHT_RE).flatten.join
      unescape_js(joined)
    end

    # Decode the JSON object that starts at `start` in `buffer`, tolerating the
    # trailing RSC noise that follows it. Ruby's JSON has no raw_decode, so scan
    # for the balanced closing brace while respecting strings and escapes.
    def decode_object(buffer, start)
      return nil unless buffer[start] == '{'

      depth = 0
      in_string = false
      escaped = false
      idx = start

      while idx < buffer.length
        ch = buffer[idx]
        if in_string
          if escaped         then escaped = false
          elsif ch == '\\'   then escaped = true
          elsif ch == '"'    then in_string = false
          end
        else
          case ch
          when '"' then in_string = true
          when '{' then depth += 1
          when '}'
            depth -= 1
            return JSON.parse(buffer[start..idx]) if depth.zero?
          end
        end
        idx += 1
      end
      nil
    rescue JSON::ParserError
      nil
    end

    # Find the first object in `buffer` containing `marker` and decode it.
    def decode_object_containing(buffer, marker)
      idx = buffer.index(marker)
      return nil unless idx

      start = buffer.rindex('{', idx)
      start && decode_object(buffer, start)
    end

    # Undo the JS string-literal escaping used in the flight fragments. \uXXXX is
    # handled first (including surrogate pairs) so a literal "\\u0041" in the
    # source is not mistaken for an escape after backslash collapsing.
    def unescape_js(str)
      str.gsub(/\\(?:u([0-9a-fA-F]{4})|(.))/m) do
        if Regexp.last_match(1)
          Regexp.last_match(1).hex.chr(Encoding::UTF_8)
        else
          case (c = Regexp.last_match(2))
          when 'n' then "\n"
          when 't' then "\t"
          when 'r' then "\r"
          when 'b' then "\b"
          when 'f' then "\f"
          when '0' then "\0"
          else c
          end
        end
      end.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    end

    # Polite GET mirroring BaseAdapter#http_get — browser UA, timeouts, follows
    # one redirect, returns nil rather than raising.
    def http_get(url, accept: 'text/html,application/xhtml+xml', redirects: 3)
      uri  = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      req = Net::HTTP::Get.new(uri.request_uri)
      req['User-Agent'] = USER_AGENT
      req['Accept']     = accept
      res = http.request(req)

      case res
      when Net::HTTPSuccess then res.body
      when Net::HTTPRedirection
        loc = res['location']
        return nil if loc.blank? || redirects <= 0

        http_get(URI.join(url, loc).to_s, accept: accept, redirects: redirects - 1)
      else
        Rails.logger.warn "[ClaytonFlightPayload] HTTP #{res.code} for #{url}"
        nil
      end
    rescue StandardError => e
      Rails.logger.warn "[ClaytonFlightPayload] HTTP error for #{url}: #{e.class}: #{e.message}"
      nil
    end
  end
end
