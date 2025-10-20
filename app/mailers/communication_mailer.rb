# frozen_string_literal: true

class CommunicationMailer < ApplicationMailer
  def send_communication(to:, subject:, body:, from_email:, from_name:, cc: nil, bcc: nil, file_attachments: [])
    # Add file attachments if present (BEFORE calling mail)
    # Renamed parameter from 'attachments' to 'file_attachments' to avoid shadowing the mail attachments method
    
    Rails.logger.info "[CommunicationMailer] Processing #{file_attachments&.length || 0} attachments"
    
    if file_attachments.present?
      file_attachments.each_with_index do |file_attachment, index|
        next unless file_attachment.present?
        
        begin
          if file_attachment.respond_to?(:original_filename) && file_attachment.respond_to?(:read)
            # ActionDispatch::Http::UploadedFile
            filename = file_attachment.original_filename
            file_content = file_attachment.read
            Rails.logger.info "[CommunicationMailer] Attaching file #{index + 1}: #{filename} (#{file_content.bytesize} bytes)"
            attachments[filename] = file_content
          elsif file_attachment.respond_to?(:path) && file_attachment.respond_to?(:read)
            # File object  
            filename = File.basename(file_attachment.path)
            file_content = file_attachment.read
            Rails.logger.info "[CommunicationMailer] Attaching file #{index + 1}: #{filename} (#{file_content.bytesize} bytes)"
            attachments[filename] = file_content
          elsif file_attachment.is_a?(Hash)
            # Hash with filename and content
            if file_attachment[:filename] && file_attachment[:content]
              Rails.logger.info "[CommunicationMailer] Attaching file #{index + 1}: #{file_attachment[:filename]}"
              attachments[file_attachment[:filename]] = file_attachment[:content]
            end
          end
        rescue => e
          Rails.logger.error "[CommunicationMailer] Failed to attach file #{index + 1}: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end
    end
    
    # Now create and send the mail
    mail(
      to: to,
      from: "#{from_name} <#{from_email}>",
      cc: cc,
      bcc: bcc,
      subject: subject
    ) do |format|
      if body&.include?('<html') || body&.include?('<body')
        format.html { render html: body.html_safe }
      else
        format.text { render plain: body }
      end
    end
  end
end
