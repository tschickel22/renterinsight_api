require 'open-uri'
require 'tempfile'
require 'open3'
require 'combine_pdf'
require 'prawn'
require 'pdf/reader'

class PreparerSigningService
  def initialize(agreement, user, sig_data)
    @agreement = agreement
    @company = agreement.company
    @user = user
    @sig_data = sig_data
  end

  # Stamps preparer signature/initials onto the agreement PDF at each preparer-assigned placement.
  # Updates document_url with the stamped PDF so signers see the preparer's signature.
  def stamp_preparer_fields(preparer_placements)
    source_url = effective_document_url
    unless source_url.present?
      return { success: false, error: 'No source document URL' }
    end

    source_pdf_data = download_pdf(source_url)
    unless source_pdf_data
      return { success: false, error: 'Failed to download source PDF' }
    end

    placements_by_page = preparer_placements.group_by { |p| (p.stringify_keys['page'] || p.stringify_keys['pageIndex'] || 0).to_i }

    begin
      # Try CombinePDF first
      stamped_data = stamp_with_combine_pdf(source_pdf_data, placements_by_page)
    rescue CombinePDF::ParsingError => e
      Rails.logger.warn("[PreparerSigningService] CombinePDF failed: #{e.message}, trying qpdf")
      stamped_data = stamp_with_qpdf(source_pdf_data, placements_by_page)
    end

    unless stamped_data
      return { success: false, error: 'Failed to stamp preparer fields onto PDF' }
    end

    # Upload stamped PDF and update document_url (not sealed_document_url — agreement is still draft)
    upload_url = upload_pdf(stamped_data)
    unless upload_url
      return { success: false, error: 'Failed to upload stamped PDF' }
    end

    @agreement.update!(document_url: upload_url)
    Rails.logger.info("[PreparerSigningService] Stamped #{preparer_placements.size} preparer fields, new document_url: #{upload_url}")

    { success: true, document_url: upload_url }
  rescue => e
    Rails.logger.error("[PreparerSigningService] Error: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    { success: false, error: e.message }
  end

  private

  def effective_document_url
    @agreement.document_url.presence ||
      (@agreement.document_urls.is_a?(Array) ? @agreement.document_urls.first : nil)
  end

  def stamp_with_combine_pdf(source_pdf_data, placements_by_page)
    source_pdf = CombinePDF.parse(source_pdf_data)

    source_pdf.pages.each_with_index do |page, page_index|
      page_placements = placements_by_page[page_index] || []
      next if page_placements.empty?

      page_box = page[:MediaBox] || page[:CropBox] || [0, 0, 612, 792]
      page_width = (page_box[2] - page_box[0]).to_f
      page_height = (page_box[3] - page_box[1]).to_f

      overlay_data = create_overlay(page_placements, page_width, page_height)
      next unless overlay_data

      overlay_pdf = CombinePDF.parse(overlay_data)
      overlay_page = overlay_pdf.pages.first
      page << overlay_page if overlay_page
    end

    source_pdf.to_pdf
  end

  def stamp_with_qpdf(source_pdf_data, placements_by_page)
    qpdf_path = `which qpdf 2>/dev/null`.strip
    if qpdf_path.empty?
      Rails.logger.error("[PreparerSigningService] qpdf not installed")
      return nil
    end

    Dir.mktmpdir('preparer_sign') do |tmpdir|
      source_path = File.join(tmpdir, 'source.pdf')
      File.binwrite(source_path, source_pdf_data)

      # Flatten annotations first
      flat_path = File.join(tmpdir, 'flattened.pdf')
      _, stderr, status = Open3.capture3('qpdf', source_path, '--flatten-annotations=all', flat_path)
      current_path = status.success? ? flat_path : source_path

      reader = PDF::Reader.new(current_path)

      placements_by_page.sort.each do |page_index, page_placements|
        next if page_placements.empty?
        next if page_index >= reader.page_count

        page = reader.pages[page_index]
        page_box = page.attributes[:MediaBox] || [0, 0, 612, 792]
        page_width = (page_box[2] - page_box[0]).to_f
        page_height = (page_box[3] - page_box[1]).to_f

        overlay_data = create_overlay(page_placements, page_width, page_height)
        next unless overlay_data

        overlay_path = File.join(tmpdir, "overlay_#{page_index}.pdf")
        File.binwrite(overlay_path, overlay_data)

        output_path = File.join(tmpdir, "stamped_#{page_index}.pdf")
        page_num = page_index + 1

        _, stderr, status = Open3.capture3(
          'qpdf', current_path,
          '--overlay', overlay_path, "--from=1", "--to=#{page_num}",
          '--', output_path
        )

        unless status.success?
          Rails.logger.error("[PreparerSigningService] qpdf overlay failed: #{stderr.strip}")
          return nil
        end

        current_path = output_path
      end

      File.binread(current_path)
    end
  end

  def create_overlay(placements, page_width, page_height)
    pdf = Prawn::Document.new(page_size: [page_width, page_height], margin: 0)

    placements.each do |raw_placement|
      p = raw_placement.stringify_keys
      field_type = (p['fieldType'] || p['field_type']).to_s.downcase

      x_pt = ((p['x'] || 0).to_f / 100.0) * page_width
      y_pt_from_top = ((p['y'] || 0).to_f / 100.0) * page_height
      w_pt = ((p['width'] || 10).to_f / 100.0) * page_width
      h_pt = ((p['height'] || 3).to_f / 100.0) * page_height
      y_pt = page_height - y_pt_from_top

      case field_type
      when 'signature'
        stamp_signature(pdf, x_pt, y_pt, w_pt, h_pt)
      when 'initials'
        stamp_initials(pdf, x_pt, y_pt, w_pt, h_pt)
      end
    end

    pdf.render
  rescue => e
    Rails.logger.error("[PreparerSigningService] Overlay creation failed: #{e.message}")
    nil
  end

  def stamp_signature(pdf, x, y, w, h)
    if @sig_data[:signature_url].present?
      stamp_image(pdf, x, y, w, h, @sig_data[:signature_url])
    elsif @sig_data[:typed_signature].present?
      stamp_typed(pdf, x, y, w, h, @sig_data[:typed_signature])
    end
  end

  def stamp_initials(pdf, x, y, w, h)
    if @sig_data[:initials_url].present?
      stamp_image(pdf, x, y, w, h, @sig_data[:initials_url])
    elsif @sig_data[:typed_initials].present?
      stamp_typed(pdf, x, y, w, h, @sig_data[:typed_initials])
    else
      # Fall back to initials from name
      initials = @user.name.to_s.split(' ').map { |n| n[0] }.join.upcase
      stamp_typed(pdf, x, y, w, h, initials) if initials.present?
    end
  end

  def stamp_typed(pdf, x, y, w, h, text)
    return false if text.blank?
    font_size = [[h * 0.7, 18].min, 8].max

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

  def stamp_image(pdf, x, y, w, h, image_data)
    return false if image_data.blank?

    tempfile = if image_data.to_s.start_with?('data:')
      decode_base64_image(image_data)
    elsif image_data.to_s.start_with?('http')
      download_image(image_data)
    else
      decode_base64_image("data:image/png;base64,#{image_data}")
    end

    return false unless tempfile

    begin
      pdf.image tempfile.path, at: [x, y], fit: [w, h]
      true
    rescue => e
      Rails.logger.warn("[PreparerSigningService] Image stamp failed: #{e.message}")
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
    Rails.logger.warn("[PreparerSigningService] Base64 decode failed: #{e.message}")
    nil
  end

  def download_pdf(url)
    URI.open(url, ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE).read
  rescue => e
    Rails.logger.error("[PreparerSigningService] PDF download error: #{e.message}")
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
    Rails.logger.warn("[PreparerSigningService] Image download error: #{e.message}")
    nil
  end

  def upload_pdf(pdf_data)
    tmp = Tempfile.new(['preparer_signed', '.pdf'])
    tmp.binmode
    tmp.write(pdf_data)
    tmp.rewind

    begin
      s3_service = S3UploadService.new
      folder = "agreements/#{@company.id}/#{@agreement.id}/preparer_signed"

      upload_file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tmp,
        filename: "preparer_signed_#{@agreement.agreement_number}_#{SecureRandom.hex(6)}.pdf",
        type: 'application/pdf'
      )

      result = s3_service.upload(upload_file, folder: folder)
      result[:url]
    rescue => e
      Rails.logger.error("[PreparerSigningService] S3 upload failed: #{e.message}")
      nil
    ensure
      tmp.close rescue nil
      tmp.unlink rescue nil
    end
  end
end
