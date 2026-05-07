# frozen_string_literal: true

require 'net/http'
require 'base64'
require 'json'

module Accounting
  class BillScanService
    class ScanError < StandardError; end

    CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
    CLAUDE_MODEL = "claude-sonnet-4-20250514"
    MAX_IMAGE_SIZE = 10_000_000  # 10MB

    def initialize(company, user = nil)
      @company = company
      @user = user
      @api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
      raise ScanError, "AI features are not configured" unless @api_key.present?
    end

    # Accepts either a file upload (ActionDispatch::Http::UploadedFile) or an S3 URL
    def scan(file_or_url)
      started_at = Time.current

      image_data, media_type = prepare_image(file_or_url)

      prompt = build_prompt

      begin
        response = call_claude(image_data, media_type, prompt)

        input_tokens = response.dig('usage', 'input_tokens') || 0
        output_tokens = response.dig('usage', 'output_tokens') || 0
        cost_cents = calculate_cost(input_tokens, output_tokens)
        response_time_ms = ((Time.current - started_at) * 1000).to_i

        content = response.dig('content', 0, 'text') || ''
        parsed = parse_response(content)

        log_usage(
          feature: 'bill_scan',
          execution_status: 'success',
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_cents: cost_cents,
          response_time_ms: response_time_ms
        )

        parsed.merge(
          usage: {
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cost_cents: cost_cents,
            response_time_ms: response_time_ms
          }
        )
      rescue => e
        log_usage(
          feature: 'bill_scan',
          execution_status: 'error',
          error_message: e.message,
          response_time_ms: ((Time.current - started_at) * 1000).to_i
        )
        raise ScanError, "Scan failed: #{e.message}"
      end
    end

    private

    def prepare_image(file_or_url)
      if file_or_url.respond_to?(:read)
        data = file_or_url.read
        file_or_url.rewind if file_or_url.respond_to?(:rewind)
        media_type = file_or_url.content_type || 'image/jpeg'

        if data.bytesize > MAX_IMAGE_SIZE
          raise ScanError, "Image too large (#{(data.bytesize / 1_000_000.0).round(1)}MB). Max is 10MB."
        end

        if media_type == 'application/pdf'
          data, media_type = pdf_to_image(data)
        end

        [Base64.strict_encode64(data), media_type]
      elsif file_or_url.is_a?(String) && file_or_url.start_with?('http')
        response = Net::HTTP.get_response(URI(file_or_url))
        raise ScanError, "Failed to download image: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        data = response.body
        media_type = response['content-type'] || 'image/jpeg'

        if media_type == 'application/pdf'
          data, media_type = pdf_to_image(data)
        end

        [Base64.strict_encode64(data), media_type]
      else
        raise ScanError, "Invalid input — provide a file upload or URL"
      end
    end

    # Returns [data, media_type]. Falls back to raw PDF (so the caller can send
    # it via the document content type) when MiniMagick isn't available.
    def pdf_to_image(pdf_data)
      if defined?(MiniMagick)
        img = MiniMagick::Image.read(pdf_data) do |b|
          b.density "200"
          b.quality "90"
        end
        img.format "png"
        [img.to_blob, 'image/png']
      else
        [pdf_data, 'application/pdf']
      end
    rescue => e
      Rails.logger.warn "[BillScan] PDF conversion failed: #{e.message}, sending raw PDF"
      [pdf_data, 'application/pdf']
    end

    def build_prompt
      <<~PROMPT
        You are an accounting data extraction assistant. Analyze this bill, receipt, or invoice image and extract the following information.

        Return ONLY valid JSON with this exact structure (no markdown, no explanation):
        {
          "vendor_name": "The vendor/supplier/store name",
          "bill_date": "YYYY-MM-DD format date of the bill/receipt",
          "due_date": "YYYY-MM-DD format if visible, null otherwise",
          "reference_number": "Invoice/receipt number if visible, null otherwise",
          "subtotal": 0.00,
          "tax_amount": 0.00,
          "total_amount": 0.00,
          "payment_terms": "Net 30, Due on Receipt, etc. if visible, null otherwise",
          "line_items": [
            {
              "description": "Item or service description",
              "amount": 0.00,
              "category_hint": "Best guess at expense category: office_supplies, utilities, repairs, travel, meals, insurance, rent, professional_services, advertising, vehicle_expense, equipment, other"
            }
          ],
          "memo": "Any relevant notes or additional info from the document",
          "confidence": 0.95
        }

        Rules:
        - Extract ALL line items visible on the document
        - If only a total is visible with no line items, create one line item with the total
        - Dates must be in YYYY-MM-DD format
        - All amounts must be numbers (not strings)
        - confidence is 0.0-1.0 indicating how confident you are in the extraction
        - If a field is not visible, use null (not empty string)
        - Do NOT include any text outside the JSON object
      PROMPT
    end

    def call_claude(image_base64, media_type, prompt)
      uri = URI(CLAUDE_API_URL)

      content = if media_type == 'application/pdf'
        [
          {
            type: "document",
            source: {
              type: "base64",
              media_type: "application/pdf",
              data: image_base64
            }
          },
          { type: "text", text: prompt }
        ]
      else
        [
          {
            type: "image",
            source: {
              type: "base64",
              media_type: media_type,
              data: image_base64
            }
          },
          { type: "text", text: prompt }
        ]
      end

      body = {
        model: CLAUDE_MODEL,
        max_tokens: 2000,
        messages: [
          { role: "user", content: content }
        ]
      }

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = body.to_json

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      http.open_timeout = 15

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue {}
        error_msg = error_body.dig('error', 'message') || response.body.to_s.first(200)
        raise ScanError, "Claude API error (#{response.code}): #{error_msg}"
      end

      JSON.parse(response.body)
    end

    def parse_response(content)
      json_str = content.gsub(/```json\s*/i, '').gsub(/```\s*/, '').strip

      parsed = JSON.parse(json_str)

      {
        vendor_name: parsed['vendor_name'],
        bill_date: parsed['bill_date'],
        due_date: parsed['due_date'],
        reference_number: parsed['reference_number'],
        subtotal: parsed['subtotal']&.to_f,
        tax_amount: parsed['tax_amount']&.to_f,
        total_amount: parsed['total_amount']&.to_f,
        payment_terms: parsed['payment_terms'],
        line_items: (parsed['line_items'] || []).map do |item|
          {
            description: item['description'],
            amount: item['amount']&.to_f || 0,
            category_hint: item['category_hint']
          }
        end,
        memo: parsed['memo'],
        confidence: parsed['confidence']&.to_f || 0
      }
    rescue JSON::ParserError => e
      raise ScanError, "Failed to parse AI response: #{e.message}"
    end

    def calculate_cost(input_tokens, output_tokens)
      # Sonnet pricing: $3/M input, $15/M output
      input_cost = (input_tokens / 1_000_000.0) * 3.0
      output_cost = (output_tokens / 1_000_000.0) * 15.0
      ((input_cost + output_cost) * 100).ceil  # cents
    end

    def log_usage(feature:, execution_status:, input_tokens: 0, output_tokens: 0, cost_cents: 0, response_time_ms: 0, error_message: nil)
      AiQueryLog.create!(
        company_id: @company.id,
        user_id: @user&.id,
        location_id: (defined?(Current) ? Current.location_id : nil),
        feature: feature,
        execution_status: execution_status,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost_cents: cost_cents,
        response_time_ms: response_time_ms,
        error_message: error_message
      )
    rescue => e
      Rails.logger.error "[BillScan] Failed to log usage: #{e.message}"
    end
  end
end
