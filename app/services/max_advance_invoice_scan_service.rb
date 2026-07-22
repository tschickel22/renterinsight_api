# frozen_string_literal: true

require 'net/http'
require 'base64'
require 'json'

# MaxAdvanceInvoiceScanService — Max Advance Phase 5. Vision-extract a manufacturer
# invoice into a DRAFT of vehicle_invoice fields (Phase 1). Reuses the Anthropic vision
# pipeline (ANTHROPIC_API_KEY), same pattern as Accounting::BillScanService.
#
# ⚠ NEVER PERSISTS. It returns a draft only. The caller presents the draft for HUMAN
# VERIFICATION and only then PATCHes the confirmed values to the vehicle_invoice (Phase 1
# endpoint). A wrong freight/allowance produces a wrong Max Sales Price and could let a
# rep price outside financeable limits — verify-before-commit is the mandatory mitigation.
#
# Known accuracy ~85% on single-page invoices, lower on the 3-page invoices; the whole PDF
# is sent as a multi-page `document` (no single-page rasterization) to give the best shot.
class MaxAdvanceInvoiceScanService
  class ScanError < StandardError; end

  CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
  CLAUDE_MODEL   = AiModel.for(:vision)
  MAX_SIZE       = 25_000_000

  # vehicle_invoice money attributes the scan maps to.
  MONEY_FIELDS = %w[
    gross_invoice base_price options_total material_surcharge factory_freight
    sales_allowance hud_fees state_assoc_fees tax_from_invoice ac_from_invoice
    total_invoice trim_out
  ].freeze

  def initialize(company, user = nil)
    @company = company
    @user = user
    @api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
    raise ScanError, 'AI features are not configured' unless @api_key.present?
  end

  # file_or_url: an uploaded file (responds to :read) or an http(s) URL (internal doc).
  # Returns a DRAFT hash — it does NOT write a vehicle_invoice.
  def scan(file_or_url)
    started = Time.current
    data, media_type = prepare_input(file_or_url)

    response       = call_claude(data, media_type, build_prompt)
    input_tokens   = response.dig('usage', 'input_tokens') || 0
    output_tokens  = response.dig('usage', 'output_tokens') || 0
    content        = response.dig('content', 0, 'text') || ''
    draft          = parse_response(content)

    log_usage('success', input_tokens, output_tokens, elapsed_ms(started))
    draft.merge(usage: { input_tokens: input_tokens, output_tokens: output_tokens })
  rescue StandardError => e
    log_usage('error', 0, 0, elapsed_ms(started), e.message)
    raise e.is_a?(ScanError) ? e : ScanError.new("Scan failed: #{e.message}")
  end

  private

  def elapsed_ms(started)
    ((Time.current - started) * 1000).to_i
  end

  def prepare_input(file_or_url)
    if file_or_url.respond_to?(:read)
      raw = file_or_url.read
      file_or_url.rewind if file_or_url.respond_to?(:rewind)
      media = file_or_url.try(:content_type).presence || guess_media(raw)
    elsif file_or_url.is_a?(String) && file_or_url.start_with?('http')
      resp = Net::HTTP.get_response(URI(file_or_url))
      raise ScanError, "Failed to download document: HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)
      raw = resp.body
      media = resp['content-type'].presence || guess_media(raw)
    else
      raise ScanError, 'Provide an uploaded file or an http(s) document URL'
    end

    raise ScanError, "Document too large (#{(raw.bytesize / 1_000_000.0).round(1)}MB). Max is 25MB." if raw.bytesize > MAX_SIZE

    media = 'application/pdf' if media.to_s.include?('pdf') # PDFs sent whole (all pages)
    [Base64.strict_encode64(raw), media]
  end

  def guess_media(raw)
    raw.to_s.start_with?('%PDF-') ? 'application/pdf' : 'image/jpeg'
  end

  def build_prompt
    <<~PROMPT
      You are extracting financial data from a MANUFACTURED-HOME MANUFACTURER'S INVOICE
      (e.g. Sunshine Homes). Read ALL pages. Return ONLY valid JSON (no markdown), exactly:
      {
        "manufacturer": "string or null",
        "model": "model name/number or null",
        "invoice_number": "string or null",
        "invoice_date": "YYYY-MM-DD or null",
        "sections": 1,
        "base_price": 0.00,
        "options_total": 0.00,
        "material_surcharge": 0.00,
        "factory_freight": 0.00,
        "sales_allowance": 0.00,
        "hud_fees": 0.00,
        "state_assoc_fees": 0.00,
        "tax_from_invoice": 0.00,
        "ac_from_invoice": 0.00,
        "trim_out": 0.00,
        "total_invoice": 0.00,
        "gross_invoice": 0.00,
        "vep_code": 0,
        "wind_zone": 2,
        "confidence": 0.0,
        "field_confidence": { "factory_freight": 0.9 }
      }
      Rules:
      - All money fields are NUMBERS, not strings. Use null when a line is not on the invoice.
      - sales_allowance: when shown as a credit/allowance, return it NEGATIVE (e.g. -1000).
      - gross_invoice = total_invoice (the manufacturer's bottom-line Total Invoice).
      - sections = number of sections (single-wide = 1, double-wide = 2); use null if unclear.
      - vep_code: the VEP stamp/code (0, 1, or 2) if present, else null.
      - wind_zone: wind zone (1, 2, or 3) if present, else null.
      - trim_out: a separate Trim Out / Tape & Texture invoice line if present, else null.
      - ac_from_invoice: a factory-installed Air Conditioner / A/C invoice line (often in the
        options detail) if present, else null. Do NOT include heat pumps or furnace lines.
      - state_assoc_fees: a State Association fee line if present, else null.
      - confidence is 0.0-1.0 overall; field_confidence is per-field where you can judge it.
      - Output ONLY the JSON object, nothing else.
    PROMPT
  end

  def call_claude(b64, media_type, prompt)
    content =
      if media_type == 'application/pdf'
        [{ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: b64 } },
         { type: 'text', text: prompt }]
      else
        [{ type: 'image', source: { type: 'base64', media_type: media_type, data: b64 } },
         { type: 'text', text: prompt }]
      end

    body = { model: CLAUDE_MODEL, max_tokens: 2000, messages: [{ role: 'user', content: content }] }

    uri = URI(CLAUDE_API_URL)
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req['x-api-key'] = @api_key
    req['anthropic-version'] = '2023-06-01'
    req.body = body.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120
    http.open_timeout = 20

    resp = http.request(req)
    unless resp.is_a?(Net::HTTPSuccess)
      eb = JSON.parse(resp.body) rescue {}
      raise ScanError, "Claude API error (#{resp.code}): #{eb.dig('error', 'message') || resp.body.to_s.first(200)}"
    end
    JSON.parse(resp.body)
  end

  def parse_response(content)
    json = content.to_s.gsub(/```json\s*/i, '').gsub(/```/, '').strip
    json = Regexp.last_match(1) if !json.start_with?('{') && json =~ /(\{.*\})/m
    p = JSON.parse(json)

    fields = {}
    MONEY_FIELDS.each { |f| fields[f] = num(p[f]) }
    fields['vep_code']       = int_or_nil(p['vep_code'])
    fields['wind_zone']      = int_or_nil(p['wind_zone'])
    fields['sections']       = int_or_nil(p['sections'])
    fields['manufacturer']   = p['manufacturer'].presence
    fields['model']          = p['model'].presence
    fields['invoice_number'] = p['invoice_number'].presence
    fields['invoice_date']   = p['invoice_date'].presence

    {
      draft: true,
      persisted: false,
      requires_verification: true,
      fields: fields,
      confidence: num(p['confidence']) || 0.0,
      field_confidence: (p['field_confidence'].is_a?(Hash) ? p['field_confidence'] : {}),
      warnings: warnings_for(fields)
    }
  rescue JSON::ParserError => e
    raise ScanError, "Failed to parse AI response: #{e.message}"
  end

  def warnings_for(fields)
    w = []
    if fields['total_invoice'] && fields['gross_invoice'] &&
       (fields['total_invoice'] - fields['gross_invoice']).abs > 1.0
      w << 'gross_invoice does not match total_invoice — verify.'
    end
    if fields['sales_allowance'] && fields['sales_allowance'] > 0
      w << 'sales_allowance is positive — it is usually a negative credit; verify the sign.'
    end
    w << 'Scanned values are unverified. Review EVERY figure before saving — a wrong freight/allowance skews the Max Sales Price.'
    w
  end

  def num(v)
    return nil if v.nil?
    v.to_s.gsub(/[$,\s]/, '').to_f
  end

  def int_or_nil(v)
    v.nil? ? nil : v.to_i
  end

  def log_usage(status, input_tokens, output_tokens, ms, error = nil)
    AiQueryLog.create!(
      company_id: @company.id,
      user_id: @user&.id,
      location_id: (defined?(Current) ? Current.location_id : nil),
      feature: 'max_advance_invoice_scan',
      execution_status: status,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_cents: calc_cost(input_tokens, output_tokens),
      response_time_ms: ms,
      error_message: error
    )
  rescue StandardError => e
    Rails.logger.error "[MaxAdvInvoiceScan] log_usage failed: #{e.message}"
  end

  def calc_cost(input_tokens, output_tokens)
    (((input_tokens / 1_000_000.0) * 3.0 + (output_tokens / 1_000_000.0) * 15.0) * 100).ceil
  end
end
