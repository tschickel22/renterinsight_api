# frozen_string_literal: true

# Converts document files (DOCX, DOC) to PDF using LibreOffice headless
# Requires: libreoffice installed on the system
#   Ubuntu/WSL: sudo apt-get install libreoffice-writer
#   Render: Add to Dockerfile or use buildpack
class DocumentConversionService
  LIBREOFFICE_BIN = ENV.fetch('LIBREOFFICE_PATH', 'libreoffice')
  TIMEOUT_SECONDS = 30

  class ConversionError < StandardError; end

  # Convert an uploaded file to PDF
  # @param uploaded_file [ActionDispatch::Http::UploadedFile] The uploaded DOCX/DOC file
  # @return [Hash] { pdf_path: String, pdf_filename: String, cleanup: Proc }
  def self.to_pdf(uploaded_file)
    # Create temp directory for this conversion
    tmp_dir = Dir.mktmpdir('docx_convert_')
    
    begin
      # Write uploaded file to temp location
      original_ext = File.extname(uploaded_file.original_filename).downcase
      safe_name = "input#{original_ext}"
      input_path = File.join(tmp_dir, safe_name)

      File.open(input_path, 'wb') do |f|
        uploaded_file.rewind if uploaded_file.respond_to?(:rewind)
        f.write(uploaded_file.read)
      end

      # Convert using LibreOffice headless
      cmd = [
        LIBREOFFICE_BIN,
        '--headless',
        '--convert-to', 'pdf',
        '--outdir', tmp_dir,
        input_path
      ]

      Rails.logger.info "[DocumentConversion] Converting: #{uploaded_file.original_filename}"

      stdout, stderr, status = nil
      Timeout.timeout(TIMEOUT_SECONDS) do
        stdout, stderr, status = Open3.capture3(*cmd)
      end

      unless status.success?
        Rails.logger.error "[DocumentConversion] Failed: #{stderr}"
        raise ConversionError, "Document conversion failed: #{stderr.truncate(200)}"
      end

      # Find the generated PDF
      pdf_path = File.join(tmp_dir, "input.pdf")
      unless File.exist?(pdf_path)
        # Sometimes LibreOffice names it differently
        pdf_files = Dir.glob(File.join(tmp_dir, '*.pdf'))
        pdf_path = pdf_files.first
      end

      unless pdf_path && File.exist?(pdf_path)
        raise ConversionError, "Conversion produced no PDF output"
      end

      pdf_filename = uploaded_file.original_filename.sub(/\.(docx?|rtf|odt)$/i, '.pdf')

      Rails.logger.info "[DocumentConversion] Success: #{pdf_filename} (#{File.size(pdf_path)} bytes)"

      {
        pdf_path: pdf_path,
        pdf_filename: pdf_filename,
        tmp_dir: tmp_dir  # Caller must clean up
      }

    rescue Timeout::Error
      FileUtils.rm_rf(tmp_dir)
      raise ConversionError, "Document conversion timed out after #{TIMEOUT_SECONDS}s"
    rescue ConversionError
      FileUtils.rm_rf(tmp_dir)
      raise
    rescue => e
      FileUtils.rm_rf(tmp_dir)
      raise ConversionError, "Unexpected conversion error: #{e.message}"
    end
  end

  # Check if LibreOffice is available
  def self.available?
    system("#{LIBREOFFICE_BIN} --version", out: File::NULL, err: File::NULL)
  end
end
