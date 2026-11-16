# frozen_string_literal: true

require 'open3'

module Agreements
  # A password-locked copy of a sensitive agreement's signed PDF, for sending a
  # credit application to a lender. AES-256 (qpdf, in the server image). The
  # password is shown once to the person sharing it and stored nowhere: they give
  # it to the lender by phone or text, never in the same email as the file.
  class LockedCopy
    # No 0/O, 1/l/I: read aloud over the phone without mix-ups.
    ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'.chars.freeze

    Result = Struct.new(:key, :password, keyword_init: true)

    PASSWORD_FORMAT = /\A[#{ALPHABET.join}]{4}-[#{ALPHABET.join}]{4}-[#{ALPHABET.join}]{4}\z/

    def self.password
      Array.new(12) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.each_slice(4).map(&:join).join('-')
    end

    def self.create!(agreement)
      raise ArgumentError, 'Only a sealed agreement can be locked' if agreement.sealed_document_url.blank?

      # Raw bytes: blank? would run a text regex over them and fail on non-UTF-8 bytes.
      pdf = PrivateFiles.read(agreement.sealed_document_url, company_id: agreement.company_id)&.b
      raise 'The signed document could not be read' if pdf.nil? || pdf.empty?

      pw = password
      locked = lock(pdf, pw)
      key = "agreements/#{agreement.company_id}/locked/#{agreement.id}-#{SecureRandom.hex(8)}.pdf"
      Result.new(key: PrivateFiles.put(locked, key: key, content_type: 'application/pdf'), password: pw)
    end

    def self.lock(pdf, pw)
      Dir.mktmpdir do |dir|
        src = File.join(dir, 'in.pdf')
        out = File.join(dir, 'out.pdf')
        File.binwrite(src, pdf)
        # Same password to open and to change it; printing allowed, editing not.
        _o, err, status = Open3.capture3('qpdf', '--encrypt', pw, pw, '256', '--modify=none', '--', src, out)
        raise "qpdf could not lock the PDF: #{err.strip}" unless status.success? || status.exitstatus == 3

        File.binread(out)
      end
    end
  end
end
