# frozen_string_literal: true

module Truebuild
  module Trueview
    module Providers
      # Google's Gemini image models (Nano Banana). The published model ids
      # carry suffixes that change between preview and release, so the id is
      # resolved against the account's model list and cached.
      module Gemini
        module_function

        BASE = 'https://generativelanguage.googleapis.com/v1beta'

        ASPECTS = { '1:1' => 1.0, '3:2' => 1.5, '2:3' => 2 / 3.0, '4:3' => 4 / 3.0, '3:4' => 0.75, '5:4' => 1.25,
                    '4:5' => 0.8, '16:9' => 16 / 9.0, '9:16' => 9 / 16.0, '21:9' => 21 / 9.0 }.freeze

        # aspect: the source photo's width / height. Asked for, because Lite
        # left to itself once drew a wide exterior as a tall portrait.
        def edit(spec, source, prompt, samples: [], aspect: nil)
          model = resolve(spec[:model])
          config = { responseModalities: ['IMAGE'] }
          image_config = {}
          image_config[:imageSize] = spec[:size] if spec[:size]
          image_config[:aspectRatio] = ASPECTS.min_by { |_, r| (Math.log(r) - Math.log(aspect)).abs }.first if aspect
          config[:imageConfig] = image_config if image_config.any?
          images = [source, *samples].map { |img| { inline_data: { mime_type: img[:mime], data: Base64.strict_encode64(img[:bytes]) } } }
          body = { contents: [{ role: 'user', parts: [{ text: prompt }, *images] }], generationConfig: config }
          res = HTTParty.post("#{BASE}/models/#{model}:generateContent", headers: headers, body: body.to_json, timeout: 180)
          raise Error, "Gemini #{res.code}: #{res.parsed_response.dig('error', 'message') || res.body.to_s.first(300)}" unless res.code == 200

          parts = res.parsed_response.dig('candidates', 0, 'content', 'parts') || []
          image = parts.find { |p| p['inlineData'] || p['inline_data'] }
          unless image
            reason = res.parsed_response.dig('candidates', 0, 'finishReason') || parts.filter_map { |p| p['text'] }.join(' ').first(300)
            raise Error, "Gemini returned no image (#{reason.presence || 'no reason given'})"
          end

          data = image['inlineData'] || image['inline_data']
          meta = res.parsed_response['usageMetadata'] || {}
          { bytes: Base64.decode64(data['data']), mime: data['mimeType'] || data['mime_type'] || 'image/png', model: model,
            usage: { 'prompt_tokens' => meta['promptTokenCount'].to_i, 'output_tokens' => meta['candidatesTokenCount'].to_i,
                     'total_tokens' => meta['totalTokenCount'].to_i } }
        end

        # "gemini-3.1-flash-image" may be published as "...-preview"; take the
        # exact id when it exists, else the shortest id that starts with it.
        def resolve(base)
          ids = Rails.cache.fetch('truebuild:trueview:gemini-models', expires_in: 1.hour) do
            res = HTTParty.get("#{BASE}/models?pageSize=1000", headers: headers, timeout: 30)
            raise Error, "Gemini model list #{res.code}: #{res.parsed_response.dig('error', 'message')}" unless res.code == 200

            Array(res.parsed_response['models']).map { |m| m['name'].to_s.delete_prefix('models/') }
          end
          return base if ids.include?(base)

          ids.select { |id| id.start_with?(base) }.min_by(&:length) or
            raise Error, "No Gemini model named #{base}* on this key. Available image models: " \
                         "#{ids.grep(/image/).first(12).join(', ').presence || 'none'}"
        end

        def headers
          key = ENV['GEMINI_API_KEY'].presence or raise Error, 'GEMINI_API_KEY is not set'
          { 'x-goog-api-key' => key, 'Content-Type' => 'application/json' }
        end
      end

      # OpenAI's image edits endpoint.
      module OpenAi
        module_function

        URL = 'https://api.openai.com/v1/images/edits'

        def edit(spec, source, prompt, samples: [])
          res = post(spec, [source, *samples], prompt, fidelity: true)
          # input_fidelity keeps the source's detail; drop it if this model refuses it.
          res = post(spec, [source, *samples], prompt, fidelity: false) if res.code == 400 && res.body.to_s.include?('input_fidelity')
          raise Error, "OpenAI #{res.code}: #{res.parsed_response.dig('error', 'message') || res.body.to_s.first(300)}" unless res.code == 200

          b64 = res.parsed_response.dig('data', 0, 'b64_json') or raise Error, 'OpenAI returned no image'
          u = res.parsed_response['usage'] || {}
          details = u['input_tokens_details'] || {}
          { bytes: Base64.decode64(b64), mime: "image/#{res.parsed_response['output_format'] || 'png'}", model: spec[:model],
            usage: { 'text_tokens' => details['text_tokens'].to_i, 'image_tokens' => details['image_tokens'].to_i,
                     'output_tokens' => u['output_tokens'].to_i, 'total_tokens' => u['total_tokens'].to_i } }
        end

        # The room first; OpenAI edits the first image and reads the rest as references.
        def post(spec, images, prompt, fidelity:)
          key = ENV['OPENAI_API_KEY'].presence or raise Error, 'OPENAI_API_KEY is not set'
          files = images.map do |img|
            Tempfile.new(['trueview', img[:mime].to_s.include?('png') ? '.png' : '.jpg'], binmode: true).tap do |f|
              f.write(img[:bytes])
              f.rewind
            end
          end
          body = { model: spec[:model], prompt: prompt, 'image[]': files.size == 1 ? files.first : files,
                   quality: spec[:quality], size: 'auto', n: 1 }
          body[:input_fidelity] = 'high' if fidelity
          HTTParty.post(URL, headers: { 'Authorization' => "Bearer #{key}" }, multipart: true, body: body, timeout: 240)
        ensure
          files&.each(&:close!)
        end
      end
    end
  end
end
