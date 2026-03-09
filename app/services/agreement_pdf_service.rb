require 'open-uri'
require 'tempfile'
require 'combine_pdf'
require 'prawn'

class AgreementPdfService
  def initialize(agreement)
    @agreement = agreement
    @company = agreement.company
  end

  # Main entry point: stamp signatures + field values onto PDF, upload sealed version
  def seal_document
    # Idempotency guard — if already sealed (e.g. job killed mid-run and retried), skip
    if @agreement.sealed_document_url.present?
      Rails.logger.info("[AgreementPdfService] Agreement #{@agreement.id} already sealed, skipping")
      return @agreement.sealed_document_url
    end

    Rails.logger.info("[AgreementPdfService] Sealing agreement #{@agreement.id}")

    source_url = effective_document_url
    unless source_url.present?
      Rails.logger.warn("[AgreementPdfService] No source document URL for agreement #{@agreement.id}")
      return nil
    end

    placements = @agreement.merge_field_placements || []

    # Download source PDF (always needed for audit certificate, even if no placements)
    source_pdf_data = download_pdf(source_url)
    unless source_pdf_data
      Rails.logger.error("[AgreementPdfService] Failed to download source PDF from #{source_url}")
      @agreement.update!(sealed_document_url: source_url)
      log_sealed!
      return source_url
    end

    Rails.logger.info("[AgreementPdfService] Downloaded #{source_pdf_data.size} bytes")

    begin
      # Load source PDF and free the raw bytes immediately — no need to hold both
      source_pdf = CombinePDF.parse(source_pdf_data)
      source_pdf_data = nil  # GC hint: release raw download bytes
      GC.compact rescue nil
      page_count = source_pdf.pages.count
      Rails.logger.info("[AgreementPdfService] Parsed PDF: #{page_count} pages")

      # Build values map (merge field key → display value)
      values_map = build_values_map
      # Build signatures map (signer_index → { signature_url, typed_signature, font })
      signatures_map = build_signatures_map

      Rails.logger.info("[AgreementPdfService] #{placements.size} placements, #{signatures_map.size} signers with signatures")

      if placements.empty?
        Rails.logger.info("[AgreementPdfService] No field placements — will still append audit certificate")
      end

      # Group placements by page
      placements_by_page = placements.group_by { |p| (p.stringify_keys['page'] || p.stringify_keys['pageIndex'] || 0).to_i }

      # For each page that has placements, create an overlay and stamp it
      overlays_applied = 0
      source_pdf.pages.each_with_index do |page, page_index|
        page_placements = placements_by_page[page_index] || []
        next if page_placements.empty?

        # Get page dimensions from the PDF page
        page_box = page[:MediaBox] || page[:CropBox] || [0, 0, 612, 792]
        page_width = (page_box[2] - page_box[0]).to_f
        page_height = (page_box[3] - page_box[1]).to_f

        Rails.logger.info("[AgreementPdfService] Page #{page_index}: #{page_width}x#{page_height} pts, #{page_placements.size} placements")

        # Create overlay PDF for this page using Prawn
        overlay_data = create_page_overlay(page_placements, page_width, page_height, values_map, signatures_map)

        if overlay_data
          overlay_pdf = CombinePDF.parse(overlay_data)
          overlay_page = overlay_pdf.pages.first
          if overlay_page
            page << overlay_page
            overlays_applied += 1
          end
        end
      end

      Rails.logger.info("[AgreementPdfService] Applied #{overlays_applied} page overlays")

      # Append audit certificate page
      begin
        cert_data = generate_audit_certificate_pdf
        if cert_data
          cert_pdf = CombinePDF.parse(cert_data)
          cert_pdf.pages.each { |cert_page| source_pdf << cert_page }
          Rails.logger.info("[AgreementPdfService] ✅ Audit certificate appended (#{cert_pdf.pages.count} page(s))")
        end
      rescue => e
        Rails.logger.error("[AgreementPdfService] Audit certificate generation failed (non-fatal): #{e.message}")
      end

      # Generate sealed PDF data and release the parsed PDF tree
      sealed_data = source_pdf.to_pdf
      source_pdf = nil  # GC hint: release parsed PDF object tree
      GC.compact rescue nil
      Rails.logger.info("[AgreementPdfService] Sealed PDF: #{sealed_data.size} bytes")

      # Upload to S3 using the same service the rest of the app uses
      sealed_url = upload_sealed_pdf(sealed_data)

      if sealed_url
        @agreement.update!(sealed_document_url: sealed_url)
        log_sealed!
        Rails.logger.info("[AgreementPdfService] ✅ Sealed document uploaded: #{sealed_url}")
        sealed_url
      else
        Rails.logger.error("[AgreementPdfService] Failed to upload sealed PDF to S3")
        @agreement.update!(sealed_document_url: source_url)
        log_sealed!
        source_url
      end

    rescue => e
      Rails.logger.error("[AgreementPdfService] Sealing failed: #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      # Fallback: use source as sealed
      @agreement.update!(sealed_document_url: source_url)
      log_sealed!
      source_url
    end
  end

  # Legacy methods
  def generate_document
    effective_document_url
  end

  def embed_signatures
    seal_document
  end

  def generate_completion_certificate
    {
      agreement_number: @agreement.agreement_number,
      title: @agreement.title,
      completed_at: @agreement.completed_at,
      signers: @agreement.agreement_signers.required_signers.map do |signer|
        { name: signer.name, email: signer.email, role: signer.role, signed_at: signer.signed_at, signature_method: signer.signature_method, ip_address: signer.ip_address }
      end,
      seal_hash: Digest::SHA256.hexdigest("#{@agreement.id}|#{@agreement.completed_at}|#{@agreement.agreement_signers.signed.pluck(:signature_hash).join('|')}")
    }
  end

  private

  def effective_document_url
    @agreement.document_url.presence ||
      (@agreement.document_urls.is_a?(Array) ? @agreement.document_urls.first : nil)
  end

  # Normalize placement keys (handle both camelCase and snake_case from JSONB)
  def normalize_placement(p)
    p = p.stringify_keys if p.is_a?(Hash)
    {
      id: p['id'],
      field_key: p['fieldKey'] || p['field_key'],
      field_label: p['fieldLabel'] || p['field_label'],
      field_type: p['fieldType'] || p['field_type'],
      page: (p['page'] || p['pageIndex'] || 0).to_i,
      x: (p['x'] || 0).to_f,
      y: (p['y'] || 0).to_f,
      width: (p['width'] || 10).to_f,
      height: (p['height'] || 3).to_f,
      signer_index: (p['signerIndex'] || p['signer_index'] || 0).to_i,
      is_signer_field: p['isSignerField'] || p['is_signer_field']
    }
  end

  # Build map of field_key → resolved value for ALL field types
  # Mirrors build_combined_merge_values in AgreementSigningController
  def build_values_map
    values = {}

    # 1. Resolve live from linked entities
    contact = @company.contacts.find_by(id: @agreement.contact_id) if @agreement.contact_id.present?
    account = @company.accounts.find_by(id: @agreement.account_id) if @agreement.account_id.present?
    deal = @company.deals.find_by(id: @agreement.deal_id) if @agreement.deal_id.present?
    vehicle = nil
    if deal&.respond_to?(:vehicle_id) && deal.vehicle_id.present?
      vehicle = @company.vehicles.find_by(id: deal.vehicle_id)
    end

    if contact
      values['contact.first_name'] = contact.first_name.to_s
      values['contact.last_name'] = contact.last_name.to_s
      values['contact.full_name'] = [contact.first_name, contact.last_name].compact.join(' ')
      values['contact.name'] = values['contact.full_name']
      values['contact.email'] = contact.email.to_s
      values['contact.phone'] = contact.phone.to_s
      values['contact.mobile_phone'] = (contact.try(:mobile_phone) || contact.try(:cell_phone)).to_s
      values['contact.street'] = (contact.try(:street) || contact.try(:address)).to_s
      values['contact.city'] = contact.try(:city).to_s
      values['contact.state'] = contact.try(:state).to_s
      values['contact.zip'] = (contact.try(:zip) || contact.try(:postal_code)).to_s
    end

    if account
      values['account.name'] = account.name.to_s
    end

    if deal
      values['deal.name'] = (deal.respond_to?(:title) ? deal.title : deal.name).to_s
      values['deal.amount'] = (deal.respond_to?(:amount) ? deal.amount : deal.try(:value)).to_s
      values['deal.owner_name'] = deal.respond_to?(:owner) ? [deal.owner&.first_name, deal.owner&.last_name].compact.join(' ') : ''
    end

    if vehicle
      values['vehicle.make'] = vehicle.try(:make).to_s
      values['vehicle.model'] = vehicle.try(:model).to_s
      values['vehicle.year'] = vehicle.try(:year).to_s
      values['vehicle.vin'] = (vehicle.try(:vin) || vehicle.try(:serial_number)).to_s
      values['vehicle.stock_number'] = vehicle.try(:stock_number).to_s
      values['vehicle.condition'] = vehicle.try(:condition)&.titleize.to_s
      values['vehicle.sections'] = vehicle.try(:sections).to_s
      values['vehicle.bedrooms'] = vehicle.try(:bedrooms).to_s
      values['vehicle.bathrooms'] = (vehicle.try(:bathrooms) || vehicle.try(:baths)).to_s
      values['vehicle.length'] = vehicle.try(:length).to_s
      values['vehicle.width'] = vehicle.try(:width).to_s
      values['vehicle.exterior_color'] = (vehicle.try(:exterior_color) || vehicle.try(:color)).to_s
      values['vehicle.price'] = (vehicle.try(:price) || vehicle.try(:msrp) || vehicle.try(:sale_price)).to_s
    end

    values['company.name'] = @company.name.to_s
    values['company.email'] = @company.try(:email).to_s
    values['company.phone'] = @company.try(:phone).to_s
    values['date.today'] = Date.today.strftime('%m/%d/%Y')
    values['date.current_year'] = Date.today.year.to_s

    # System/agreement fields
    values['agreement.agreement_number'] = @agreement.agreement_number.to_s
    values['agreement.title'] = @agreement.title.to_s
    values['agreement.created_at'] = @agreement.created_at&.strftime('%m/%d/%Y').to_s
    values['agreement.completed_at'] = @agreement.completed_at&.strftime('%m/%d/%Y').to_s

    # 2. Merge stored merge_field_values (fill gaps)
    if @agreement.merge_field_values.is_a?(Hash)
      @agreement.merge_field_values.each do |k, v|
        next if v.nil? || v.to_s.strip.empty?
        values[k.to_s] = v.to_s unless values[k.to_s].present?
      end
    end

    # 3. Custom field values with 'custom.' prefix
    if @agreement.custom_field_values.is_a?(Hash)
      @agreement.custom_field_values.each do |k, v|
        next if v.nil?
        values["custom.#{k}"] = v.to_s
      end
    end

    values.reject! { |_, v| v.blank? }
    Rails.logger.info("[AgreementPdfService] Values map: #{values.size} entries (#{values.keys.first(10).join(', ')}...)")
    values
  end

  # Build map of signer_index → signature data
  def build_signatures_map
    signers = @agreement.agreement_signers.order(:signing_order, :id)
    map = {}

    signers.each_with_index do |signer, idx|
      next unless signer.status == AgreementSigner::STATUS_SIGNED

      sig_url = signer.signature_url
      Rails.logger.info("[AgreementPdfService] Signer[#{idx}] #{signer.name}: method=#{signer.signature_method}, signature_url=#{sig_url.present? ? "#{sig_url.to_s[0..30]}..." : 'nil'}, typed=#{signer.typed_signature}")

      map[idx] = {
        name: signer.name,
        email: signer.email,
        signature_url: sig_url,
        signature_method: signer.signature_method,
        typed_signature: signer.typed_signature,
        signature_font: signer.signature_font,
        initials_url: signer.initials_url,
        typed_initials: signer.typed_initials,
        signed_at: signer.signed_at
      }
    end

    map
  end

  # Create a transparent Prawn overlay PDF for one page
  def create_page_overlay(placements, page_width, page_height, values_map, signatures_map)
    pdf = Prawn::Document.new(
      page_size: [page_width, page_height],
      margin: 0
    )

    stamps_applied = 0

    placements.each do |raw_placement|
      p = normalize_placement(raw_placement)

      # Convert percentage positions to PDF points
      x_pt = (p[:x] / 100.0) * page_width
      y_pt_from_top = (p[:y] / 100.0) * page_height
      w_pt = (p[:width] / 100.0) * page_width
      h_pt = (p[:height] / 100.0) * page_height

      # Convert to Prawn coordinates (bottom-left origin)
      y_pt = page_height - y_pt_from_top

      field_type = p[:field_type].to_s
      field_key = p[:field_key].to_s
      signer_idx = p[:signer_index]

      Rails.logger.debug("[AgreementPdfService] Stamping: type=#{field_type} key=#{field_key} signer=#{signer_idx} at (#{x_pt.round(1)}, #{y_pt.round(1)}) #{w_pt.round(1)}x#{h_pt.round(1)}")

      # Look up value from multiple sources
      value = values_map[field_key] || values_map[p[:id].to_s] || ''

      applied = case field_type.downcase
      when 'signature'
        stamp_signature(pdf, x_pt, y_pt, w_pt, h_pt, signer_idx, signatures_map)
      when 'initials'
        stamp_initials(pdf, x_pt, y_pt, w_pt, h_pt, signer_idx, signatures_map)
      when 'date_signed'
        stamp_date_signed(pdf, x_pt, y_pt, w_pt, h_pt, signer_idx, signatures_map)
      when 'signer_name'
        stamp_signer_name(pdf, x_pt, y_pt, w_pt, h_pt, signer_idx, signatures_map)
      when 'signer_email'
        stamp_signer_email(pdf, x_pt, y_pt, w_pt, h_pt, signer_idx, signatures_map)
      when 'checkbox', 'custom_checkbox'
        stamp_checkbox(pdf, x_pt, y_pt, w_pt, h_pt, value)
      else
        # All other types: text, currency, number, date, text_input, custom_text, etc.
        stamp_text(pdf, x_pt, y_pt, w_pt, h_pt, value) if value.present?
      end

      stamps_applied += 1 if applied
    end

    Rails.logger.info("[AgreementPdfService] Overlay: #{stamps_applied}/#{placements.size} stamps applied")
    pdf.render
  rescue => e
    Rails.logger.error("[AgreementPdfService] Overlay creation failed: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    nil
  end

  # ── Stamp helpers ────────────────────────────────────────────────────

  def stamp_signature(pdf, x, y, w, h, signer_idx, signatures_map)
    signer = signatures_map[signer_idx]
    unless signer
      Rails.logger.warn("[AgreementPdfService] No signer data for index #{signer_idx}")
      return false
    end

    if signer[:signature_url].present?
      stamp_image(pdf, x, y, w, h, signer[:signature_url])
    elsif signer[:typed_signature].present?
      stamp_typed_signature(pdf, x, y, w, h, signer[:typed_signature])
    else
      Rails.logger.warn("[AgreementPdfService] Signer #{signer_idx} has no signature data")
      false
    end
  end

  def stamp_initials(pdf, x, y, w, h, signer_idx, signatures_map)
    signer = signatures_map[signer_idx]
    return false unless signer

    if signer[:initials_url].present?
      stamp_image(pdf, x, y, w, h, signer[:initials_url])
    elsif signer[:typed_initials].present?
      stamp_typed_signature(pdf, x, y, w, h, signer[:typed_initials])
    else
      initials = signer[:name].to_s.split(' ').map { |n| n[0] }.join.upcase
      stamp_typed_signature(pdf, x, y, w, h, initials) if initials.present?
    end
  end

  def stamp_date_signed(pdf, x, y, w, h, signer_idx, signatures_map)
    signer = signatures_map[signer_idx]
    return false unless signer
    date_str = signer[:signed_at]&.strftime('%m/%d/%Y') || Time.current.strftime('%m/%d/%Y')
    stamp_text(pdf, x, y, w, h, date_str)
  end

  def stamp_signer_name(pdf, x, y, w, h, signer_idx, signatures_map)
    signer = signatures_map[signer_idx]
    return false unless signer
    stamp_text(pdf, x, y, w, h, signer[:name].to_s)
  end

  def stamp_signer_email(pdf, x, y, w, h, signer_idx, signatures_map)
    signer = signatures_map[signer_idx]
    return false unless signer
    stamp_text(pdf, x, y, w, h, signer[:email].to_s)
  end

  def stamp_text(pdf, x, y, w, h, text)
    return false if text.blank?
    font_size = [h * 0.65, 12].min
    font_size = [font_size, 6].max

    pdf.font("Helvetica", size: font_size)
    pdf.fill_color '1a1a1a'
    pdf.text_box text.to_s,
      at: [x, y],
      width: w,
      height: h,
      overflow: :shrink_to_fit,
      min_font_size: 5,
      valign: :center
    true
  end

  def stamp_typed_signature(pdf, x, y, w, h, text)
    return false if text.blank?
    font_size = [h * 0.7, 18].min
    font_size = [font_size, 8].max

    pdf.font("Times-Roman", style: :italic, size: font_size)
    pdf.fill_color '000066'
    pdf.text_box text.to_s,
      at: [x, y],
      width: w,
      height: h,
      overflow: :shrink_to_fit,
      min_font_size: 6,
      valign: :center
    true
  end

  def stamp_checkbox(pdf, x, y, w, h, value)
    # Handle various truthy formats from frontend
    checked = value.present? && value.to_s.downcase.strip.in?(%w[true yes 1 on checked ✓ ✔ x])
    return false unless checked

    pdf.fill_color '1a6b1a'
    center_x = x + w / 2
    center_y = y - h / 2
    size = [w, h].min * 0.6

    pdf.stroke_color '1a6b1a'
    pdf.line_width 1.5
    pdf.stroke do
      pdf.move_to(center_x - size * 0.3, center_y)
      pdf.line_to(center_x - size * 0.05, center_y - size * 0.3)
      pdf.line_to(center_x + size * 0.35, center_y + size * 0.3)
    end
    true
  end

  def stamp_image(pdf, x, y, w, h, image_data)
    return false if image_data.blank?

    tempfile = if image_data.to_s.start_with?('data:')
      decode_base64_image(image_data)
    elsif image_data.to_s.start_with?('http')
      download_image(image_data)
    else
      # Might be raw base64 without data: prefix
      decode_base64_image("data:image/png;base64,#{image_data}")
    end

    return false unless tempfile

    begin
      pdf.image tempfile.path,
        at: [x, y],
        fit: [w, h]
      true
    rescue => e
      Rails.logger.warn("[AgreementPdfService] Image stamp failed: #{e.class}: #{e.message}")
      false
    ensure
      tempfile.close rescue nil
      tempfile.unlink rescue nil
    end
  end

  def decode_base64_image(data_uri)
    return nil if data_uri.blank?
    raw_data = data_uri.to_s.sub(/^data:image\/\w+;base64,/, '')
    decoded = Base64.decode64(raw_data)

    tempfile = Tempfile.new(['sig', '.png'])
    tempfile.binmode
    tempfile.write(decoded)
    tempfile.rewind
    tempfile
  rescue => e
    Rails.logger.warn("[AgreementPdfService] Base64 decode failed: #{e.class}: #{e.message}")
    nil
  end

  # ── Download helpers ─────────────────────────────────────────────────

  # Use URI.open — same approach as AgreementDocumentsController#merge which works
  def download_pdf(url)
    Rails.logger.info("[AgreementPdfService] Downloading PDF from: #{url}")
    data = URI.open(url, ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE).read
    Rails.logger.info("[AgreementPdfService] Downloaded #{data.size} bytes")
    data
  rescue => e
    Rails.logger.error("[AgreementPdfService] PDF download error: #{e.class}: #{e.message}")
    nil
  end

  def download_image(url)
    return nil if url.blank?

    tempfile = Tempfile.new(['sig', '.png'])
    tempfile.binmode

    data = URI.open(url, ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE).read
    tempfile.write(data)
    tempfile.rewind
    tempfile
  rescue => e
    Rails.logger.warn("[AgreementPdfService] Image download error: #{e.class}: #{e.message}")
    nil
  end

  # ── S3 upload (uses same S3UploadService as rest of app) ─────────────

  def upload_sealed_pdf(pdf_data)
    # Write to temp file
    tmp = Tempfile.new(['sealed', '.pdf'])
    tmp.binmode
    tmp.write(pdf_data)
    tmp.rewind

    begin
      s3_service = S3UploadService.new
      folder = "agreements/#{@company.id}/sealed"

      # Create an upload-like object that S3UploadService expects
      upload_file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tmp,
        filename: "sealed_#{@agreement.agreement_number}_#{SecureRandom.hex(6)}.pdf",
        type: 'application/pdf'
      )

      result = s3_service.upload(upload_file, folder: folder)
      Rails.logger.info("[AgreementPdfService] S3 upload result: #{result[:url]}")
      result[:url]
    rescue => e
      Rails.logger.error("[AgreementPdfService] S3 upload failed: #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      nil
    ensure
      tmp.close rescue nil
      tmp.unlink rescue nil
    end
  end

  # ── Audit Certificate ─────────────────────────────────────────────────

  def generate_audit_certificate_pdf
    signers = @agreement.agreement_signers.required_signers.order(:signing_order, :id)
    audit_logs = @agreement.agreement_audit_logs.order(created_at: :asc)
    completed_at = @agreement.completed_at || Time.current

    # Document fingerprint
    sig_hashes = signers.signed.map { |s| s.signature_hash.to_s }.join('|')
    document_hash = Digest::SHA256.hexdigest(
      "#{@agreement.id}|#{@agreement.agreement_number}|#{completed_at.iso8601}|#{sig_hashes}"
    )
    envelope_id = "ENV-#{@agreement.id}-#{document_hash[0..7].upcase}"

    pdf = Prawn::Document.new(
      page_size: 'LETTER',
      margin: [50, 50, 50, 50]
    )

    # ── Header bar ──────────────────────────────────────────────────────
    pdf.fill_color '1e3a5f'
    pdf.fill_rectangle [pdf.bounds.left, pdf.cursor + 10], pdf.bounds.width, 55
    pdf.fill_color 'ffffff'
    pdf.font('Helvetica', style: :bold, size: 20) do
      pdf.text_box 'Certificate of Completion',
        at: [15, pdf.cursor + 5],
        width: pdf.bounds.width - 30,
        height: 40,
        valign: :center
    end
    pdf.move_down 60

    # ── Envelope ID & Status ────────────────────────────────────────────
    pdf.fill_color '333333'
    pdf.font('Helvetica', size: 9) do
      pdf.text "Envelope ID: #{envelope_id}", color: '666666'
      pdf.text "Status: Completed", color: '166534'
    end
    pdf.move_down 15

    # ── Agreement Details ───────────────────────────────────────────────
    section_header(pdf, 'Agreement Details')

    details = [
      ['Title:', @agreement.title.to_s],
      ['Agreement #:', @agreement.agreement_number.to_s],
      ['Created:', @agreement.created_at&.strftime('%B %d, %Y %l:%M %p %Z')],
      ['Sent:', @agreement.sent_at&.strftime('%B %d, %Y %l:%M %p %Z')],
      ['Completed:', completed_at.strftime('%B %d, %Y %l:%M %p %Z')],
    ]
    details << ['Prepared By:', "#{@agreement.prepared_by&.full_name} (#{@agreement.prepared_by&.email})"] if @agreement.prepared_by.present?
    details << ['Company:', @company.name] if @company.present?
    details << ['Location:', @agreement.location&.name] if @agreement.location.present?

    detail_table(pdf, details)
    pdf.move_down 15

    # ── Signing Summary ─────────────────────────────────────────────────
    section_header(pdf, 'Signing Summary')

    if signers.any?
      table_data = [['Name', 'Email', 'Role', 'Status', 'Signed At', 'IP Address', 'Method']]

      signers.each do |signer|
        table_data << [
          signer.name,
          signer.email,
          signer.role.to_s.titleize,
          signer.status.to_s.titleize,
          signer.signed_at&.strftime('%m/%d/%Y %l:%M %p') || '—',
          signer.ip_address || '—',
          (signer.signature_method || '—').to_s.titleize
        ]
      end

      pdf.table(table_data, width: pdf.bounds.width, cell_style: { size: 7.5, padding: [4, 5], border_width: 0.5, border_color: 'cccccc' }) do |t|
        t.row(0).font_style = :bold
        t.row(0).background_color = 'f1f5f9'
        t.row(0).text_color = '334155'
        t.columns(0..6).align = :left
        t.cells.border_color = 'e2e8f0'
      end
    end

    pdf.move_down 15

    # ── Document Integrity ──────────────────────────────────────────────
    section_header(pdf, 'Document Integrity')

    integrity_data = [
      ['Document Fingerprint (SHA-256):', document_hash],
      ['Total Pages:', (@agreement.merge_field_placements&.map { |p| (p.stringify_keys['page'] || p.stringify_keys['pageIndex'] || 0).to_i }.max.to_i + 1).to_s],
      ['Signers Required:', signers.count.to_s],
      ['Signers Completed:', signers.signed.count.to_s],
    ]
    if @agreement.document_url.present?
      integrity_data << ['Source Document:', @agreement.document_url.split('/').last.to_s.truncate(60)]
    end

    detail_table(pdf, integrity_data)
    pdf.move_down 15

    # ── Audit Trail ─────────────────────────────────────────────────────
    # Check if we need a new page before the audit trail
    if pdf.cursor < 200
      pdf.start_new_page
    end

    section_header(pdf, 'Audit Trail')

    if audit_logs.any?
      trail_data = [['Timestamp', 'Action', 'Performed By', 'IP Address', 'Details']]

      audit_logs.each do |log|
        performer = if log.performed_by.is_a?(User)
          "#{log.performed_by.full_name} (User)"
        elsif log.performed_by.is_a?(AgreementSigner)
          "#{log.performed_by.name} (Signer)"
        elsif log.agreement_signer.present?
          "#{log.agreement_signer.name} (Signer)"
        else
          'System'
        end

        details = case log.action
        when 'signed'
          method = log.metadata&.dig('signature_method') || log.agreement_signer&.signature_method
          method.present? ? "Method: #{method.titleize}" : ''
        when 'viewed'
          ua = log.user_agent.to_s.truncate(40)
          ua.present? ? "Browser: #{ua}" : ''
        when 'declined'
          reason = log.metadata&.dig('reason')
          reason.present? ? "Reason: #{reason.truncate(40)}" : ''
        when 'voided'
          reason = log.metadata&.dig('reason')
          reason.present? ? "Reason: #{reason.truncate(40)}" : ''
        else
          ''
        end

        trail_data << [
          log.created_at.strftime('%m/%d/%Y %l:%M:%S %p'),
          format_audit_action(log.action),
          performer.truncate(30),
          log.ip_address || '—',
          details.truncate(45)
        ]
      end

      # Split into chunks if too many rows (Prawn table can overflow)
      trail_data.each_slice(30).with_index do |chunk, idx|
        chunk.unshift(trail_data.first) if idx > 0 # Re-add header row

        pdf.start_new_page if idx > 0

        pdf.table(chunk, width: pdf.bounds.width, cell_style: { size: 7, padding: [3, 4], border_width: 0.5 }) do |t|
          t.row(0).font_style = :bold
          t.row(0).background_color = 'f1f5f9'
          t.row(0).text_color = '334155'
          t.cells.border_color = 'e2e8f0'
          t.column(0).width = 110
          t.column(1).width = 80
          t.column(3).width = 80
        end
      end
    else
      pdf.font('Helvetica', size: 9, style: :italic) do
        pdf.text 'No audit events recorded.', color: '999999'
      end
    end

    # ── Footer ──────────────────────────────────────────────────────────
    pdf.move_down 20
    pdf.stroke_color 'cccccc'
    pdf.stroke_horizontal_rule
    pdf.move_down 8

    pdf.font('Helvetica', size: 7) do
      pdf.fill_color '999999'
      company_name = @company&.name || 'Platform DMS'
      pdf.text "This certificate was automatically generated by #{company_name} e-signature system.", align: :center
      pdf.text "Document sealed on #{completed_at.strftime('%B %d, %Y at %l:%M %p %Z')}. Envelope ID: #{envelope_id}", align: :center
      pdf.move_down 4
      pdf.text "Fingerprint: #{document_hash}", align: :center, size: 6, color: 'bbbbbb'
    end

    pdf.render
  rescue => e
    Rails.logger.error("[AgreementPdfService] Audit certificate generation error: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    nil
  end

  def section_header(pdf, title)
    pdf.fill_color '1e3a5f'
    pdf.font('Helvetica', style: :bold, size: 11) do
      pdf.text title
    end
    pdf.stroke_color '3b82f6'
    pdf.line_width = 1.5
    pdf.stroke_horizontal_rule
    pdf.move_down 8
    pdf.fill_color '333333'
    pdf.line_width = 1
  end

  def detail_table(pdf, rows)
    pdf.table(rows, width: pdf.bounds.width, cell_style: { size: 9, padding: [3, 5], border_width: 0 }) do |t|
      t.column(0).font_style = :bold
      t.column(0).text_color = '64748b'
      t.column(0).width = 160
      t.column(1).text_color = '1e293b'
    end
  end

  def format_audit_action(action)
    {
      'created' => 'Agreement Created',
      'sent' => 'Sent for Signing',
      'viewed' => 'Document Viewed',
      'signed' => 'Signature Applied',
      'declined' => 'Signing Declined',
      'voided' => 'Agreement Voided',
      'completed' => 'All Signatures Complete',
      'reminder_sent' => 'Reminder Sent',
      'expired' => 'Agreement Expired',
      'downloaded' => 'Document Downloaded',
      'sealed' => 'Document Sealed',
      'prepared_signature' => 'Prepared Signature',
      'field_completed' => 'Field Completed',
      'attachment_added' => 'Attachment Added',
      'attachment_removed' => 'Attachment Removed',
      'signer_added' => 'Signer Added',
      'signer_removed' => 'Signer Removed'
    }[action.to_s] || action.to_s.titleize
  end

  def log_sealed!
    AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_SEALED, metadata: {
      sealed_at: Time.current.iso8601,
      signers_count: @agreement.agreement_signers.signed.count
    })
  end
end
