# frozen_string_literal: true

module Truebuild
  module Trueview
    # Gemini's batch mode: many drawings in one job at half the price,
    # returned within 24 hours (usually far sooner). A scheduled factory run
    # draws this way (Batch); a buyer's drawings never do.
    #
    # The requests go up as a JSONL file (one line per drawing, keyed), the
    # batch is created from it, polled, and its results come back as a JSONL
    # file keyed the same way. https://ai.google.dev/gemini-api/docs/batch-mode
    module GeminiBatch
      module_function

      BASE = Providers::Gemini::BASE
      UPLOAD = 'https://generativelanguage.googleapis.com/upload/v1beta/files'
      DOWNLOAD = 'https://generativelanguage.googleapis.com/download/v1beta'
      DONE = %w[JOB_STATE_SUCCEEDED BATCH_STATE_SUCCEEDED].freeze
      FAILED = %w[JOB_STATE_FAILED JOB_STATE_CANCELLED JOB_STATE_EXPIRED BATCH_STATE_FAILED BATCH_STATE_CANCELLED
                  BATCH_STATE_EXPIRED].freeze
      DISCOUNT = 0.5 # batch price against the immediate price

      # lines: [[key, generateContent body]]. => the batch's name ("batches/...").
      def submit(model, lines, display_name:)
        jsonl = lines.map { |key, body| { key: key, request: body }.to_json }.join("\n")
        file = upload(jsonl, display_name)
        res = HTTParty.post("#{BASE}/models/#{model}:batchGenerateContent", headers: headers, timeout: 120,
                            body: { batch: { display_name: display_name, input_config: { file_name: file } } }.to_json)
        Credits.check!(res)
        raise Error, "Gemini batch #{res.code}: #{error(res)}" unless res.code == 200

        res.parsed_response['name'] or raise Error, 'Gemini batch: no name returned'
      end

      # => { state:, done:, failed:, responses_file: }
      def status(name)
        res = HTTParty.get("#{BASE}/#{name}", headers: headers, timeout: 60)
        raise Error, "Gemini batch status #{res.code}: #{error(res)}" unless res.code == 200

        body = res.parsed_response
        meta = body['metadata'] || body
        state = meta['state'] || body['state']
        out = meta.dig('output', 'responsesFile') || body.dig('response', 'responsesFile') || meta['responsesFile']
        { state: state, done: DONE.include?(state) || body['done'] == true && FAILED.exclude?(state),
          failed: FAILED.include?(state), responses_file: out }
      end

      # The results: { key => response hash } and { key => error message }.
      def results(responses_file)
        res = HTTParty.get("#{DOWNLOAD}/#{responses_file}:download?alt=media", headers: headers, timeout: 300)
        raise Error, "Gemini batch results #{res.code}: #{error(res)}" unless res.code == 200

        res.body.to_s.each_line.each_with_object([{}, {}]) do |line, (ok, bad)|
          next if line.strip.empty?

          row = JSON.parse(line)
          key = row['key'] || row.dig('metadata', 'key')
          if row['response'] then ok[key] = row['response']
          else bad[key] = row.dig('error', 'message') || row['status']&.to_s || 'no response'
          end
        end
      end

      def upload(bytes, display_name)
        start = HTTParty.post(UPLOAD, timeout: 60,
                                      headers: headers.merge('X-Goog-Upload-Protocol' => 'resumable', 'X-Goog-Upload-Command' => 'start',
                                                             'X-Goog-Upload-Header-Content-Length' => bytes.bytesize.to_s,
                                                             'X-Goog-Upload-Header-Content-Type' => 'application/jsonl'),
                                      body: { file: { display_name: display_name } }.to_json)
        url = start.headers['x-goog-upload-url'] or raise Error, "Gemini upload #{start.code}: #{error(start)}"
        done = HTTParty.post(url, timeout: 300, body: bytes,
                                  headers: { 'Content-Length' => bytes.bytesize.to_s, 'X-Goog-Upload-Offset' => '0',
                                             'X-Goog-Upload-Command' => 'upload, finalize' })
        raise Error, "Gemini upload #{done.code}: #{error(done)}" unless done.code == 200

        done.parsed_response.dig('file', 'name') or raise Error, 'Gemini upload: no file name returned'
      end

      def error(res)
        (res.parsed_response.is_a?(Hash) && res.parsed_response.dig('error', 'message')) || res.body.to_s.first(300)
      end

      def headers
        Providers::Gemini.headers
      end
    end
  end
end
