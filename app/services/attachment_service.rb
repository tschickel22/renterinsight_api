# frozen_string_literal: true

class AttachmentService
  # Maximum file size: 25MB
  MAX_FILE_SIZE = 25.megabytes
  
  # Allowed MIME types for attachments
  ALLOWED_MIME_TYPES = {
    # Documents
    'application/pdf' => '.pdf',
    'application/msword' => '.doc',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => '.docx',
    'application/vnd.ms-excel' => '.xls',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => '.xlsx',
    'text/plain' => '.txt',
    'text/csv' => '.csv',
    
    # Images
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    
    # Archives
    'application/zip' => '.zip',
    'application/x-rar-compressed' => '.rar'
  }.freeze
  
  class << self
    # Validate an attachment file
    # Returns { valid: true/false, errors: [] }
    def validate_attachment(file)
      errors = []
      
      # Check if file exists
      if file.nil?
        errors << "File is required"
        return { valid: false, errors: errors }
      end
      
      # Check file size
      if file.size > MAX_FILE_SIZE
        errors << "File size exceeds maximum allowed size of #{MAX_FILE_SIZE / 1.megabyte}MB"
      end
      
      # Check MIME type
      content_type = file.content_type
      unless ALLOWED_MIME_TYPES.key?(content_type)
        errors << "File type '#{content_type}' is not allowed. Allowed types: #{allowed_extensions.join(', ')}"
      end
      
      # Check filename
      if file.original_filename.blank?
        errors << "Filename is required"
      end
      
      {
        valid: errors.empty?,
        errors: errors
      }
    end
    
    # Attach file to a communication
    def attach_to_communication(communication, file)
      validation = validate_attachment(file)
      
      unless validation[:valid]
        Rails.logger.error("Attachment validation failed: #{validation[:errors].join(', ')}")
        return { success: false, errors: validation[:errors] }
      end
      
      begin
        communication.attachments.attach(file)
        
        {
          success: true,
          attachment: communication.attachments.last,
          filename: file.original_filename,
          size: file.size,
          content_type: file.content_type
        }
      rescue => e
        Rails.logger.error("Failed to attach file: #{e.message}")
        {
          success: false,
          errors: ["Failed to attach file: #{e.message}"]
        }
      end
    end
    
    # Attach multiple files to a communication
    def attach_multiple_to_communication(communication, files)
      results = {
        success: true,
        attached: [],
        failed: []
      }
      
      files.each do |file|
        result = attach_to_communication(communication, file)
        
        if result[:success]
          results[:attached] << result
        else
          results[:success] = false
          results[:failed] << {
            filename: file.original_filename,
            errors: result[:errors]
          }
        end
      end
      
      results
    end
    
    # Get attachment info
    def attachment_info(attachment)
      {
        id: attachment.id,
        filename: attachment.filename.to_s,
        size: attachment.byte_size,
        content_type: attachment.content_type,
        url: attachment.url,
        created_at: attachment.created_at
      }
    end
    
    # Get list of allowed extensions
    def allowed_extensions
      ALLOWED_MIME_TYPES.values.uniq
    end
    
    # Check if content type is allowed
    def allowed_content_type?(content_type)
      ALLOWED_MIME_TYPES.key?(content_type)
    end
    
    # Get total size of attachments for a communication
    def total_size(communication)
      communication.attachments.sum(&:byte_size)
    end
    
    # Format file size for display
    def format_size(bytes)
      if bytes < 1.kilobyte
        "#{bytes} B"
      elsif bytes < 1.megabyte
        "#{(bytes / 1.kilobyte.to_f).round(2)} KB"
      else
        "#{(bytes / 1.megabyte.to_f).round(2)} MB"
      end
    end
  end
end
