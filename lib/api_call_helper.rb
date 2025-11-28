module ApiCallHelper
  attr_accessor :response, :response_data, :log

  # Initialize a new API call log
  def api_initialize(log_enabled = true, remote_ip = nil)
    @log_enabled = log_enabled
    @remote_ip = remote_ip
    
    if @log_enabled
      @log = ApiLog.new(
        company_id: @company&.id,
        provider: 'zego',
        ip_address: remote_ip,
        status: 'pending'
      )
    end
  end

  # Mark the start of an API call
  def api_start(action, url, request_data = nil)
    return unless @log_enabled && @log

    @log.action = action
    @log.url = url
    @log.request = request_data
    @log.started_at = Time.current
    @log.save
  end

  # Mark API call as successful
  def api_success(response_body, log_to_console = false)
    if @log_enabled && @log
      @log.response = response_body
      @log.status = 'success'
      @log.completed_at = Time.current
      @log.save
    end

    if log_to_console
      Rails.logger.info "API Success: #{@log&.action}"
    end
  end

  # Mark API call as failed
  def api_failure(response_body)
    if @log_enabled && @log
      @log.response = response_body
      @log.status = 'failure'
      @log.completed_at = Time.current
      @log.save
    end

    Rails.logger.error "API Failure: #{@log&.action} - #{response_body&.truncate(200)}"
  end

  # Mark API call as error
  def api_error(error_message)
    if @log_enabled && @log
      @log.response = error_message
      @log.status = 'error'
      @log.completed_at = Time.current
      @log.save
    end

    Rails.logger.error "API Error: #{@log&.action} - #{error_message&.truncate(200)}"
  end
end
