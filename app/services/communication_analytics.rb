# frozen_string_literal: true

class CommunicationAnalytics
  class << self
    # Get aggregate statistics for communications
    def aggregate_stats(filters = {})
      scope = apply_filters(Communication.all, filters)
      
      {
        total: scope.count,
        by_status: count_by_status(scope),
        by_channel: count_by_channel(scope),
        by_direction: count_by_direction(scope),
        delivery_rate: calculate_delivery_rate(scope),
        failure_rate: calculate_failure_rate(scope),
        average_time_to_delivery: average_delivery_time(scope)
      }
    end
    
    # Get open rates for email communications
    def open_rates(filters = {})
      scope = apply_filters(Communication.email, filters)
      
      total_emails = scope.count
      return { rate: 0, total: 0, opened: 0 } if total_emails.zero?
      
      opened_count = scope.joins(:communication_events)
                          .where(communication_events: { event_type: 'opened' })
                          .distinct
                          .count
      
      {
        rate: (opened_count.to_f / total_emails * 100).round(2),
        total: total_emails,
        opened: opened_count,
        percentage: "#{((opened_count.to_f / total_emails * 100).round(2))}%"
      }
    end
    
    # Get click rates for email communications
    def click_rates(filters = {})
      scope = apply_filters(Communication.email, filters)
      
      total_emails = scope.count
      return { rate: 0, total: 0, clicked: 0 } if total_emails.zero?
      
      clicked_count = scope.joins(:communication_events)
                           .where(communication_events: { event_type: 'clicked' })
                           .distinct
                           .count
      
      {
        rate: (clicked_count.to_f / total_emails * 100).round(2),
        total: total_emails,
        clicked: clicked_count,
        percentage: "#{((clicked_count.to_f / total_emails * 100).round(2))}%"
      }
    end
    
    # Get delivery rates by channel
    def delivery_rates_by_channel(filters = {})
      scope = apply_filters(Communication.all, filters)
      
      %w[email sms portal_message].map do |channel|
        channel_scope = scope.where(channel: channel)
        total = channel_scope.count
        
        next if total.zero?
        
        delivered = channel_scope.where(status: 'delivered').count
        
        {
          channel: channel,
          total: total,
          delivered: delivered,
          rate: (delivered.to_f / total * 100).round(2),
          percentage: "#{((delivered.to_f / total * 100).round(2))}%"
        }
      end.compact
    end
    
    # Get communication volume over time
    def volume_over_time(period: 'day', filters: {})
      scope = apply_filters(Communication.all, filters)
      
      case period
      when 'hour'
        group_by_hour(scope)
      when 'day'
        group_by_day(scope)
      when 'week'
        group_by_week(scope)
      when 'month'
        group_by_month(scope)
      else
        group_by_day(scope)
      end
    end
    
    # Get response time statistics
    def response_time_stats(filters = {})
      scope = apply_filters(Communication.inbound, filters)
      
      response_times = []
      
      scope.find_each do |inbound|
        # Find next outbound communication in the same thread
        outbound = Communication.outbound
                                .where(communication_thread_id: inbound.communication_thread_id)
                                .where('created_at > ?', inbound.created_at)
                                .order(:created_at)
                                .first
        
        if outbound
          response_time = (outbound.created_at - inbound.created_at) / 60.0 # in minutes
          response_times << response_time
        end
      end
      
      return {} if response_times.empty?
      
      {
        average: response_times.sum / response_times.size,
        median: calculate_median(response_times),
        min: response_times.min,
        max: response_times.max,
        total_analyzed: response_times.size
      }
    end
    
    # Get template performance statistics
    def template_performance(filters = {})
      scope = apply_filters(Communication.where.not(template_id: nil), filters)
      
      template_stats = scope.group(:template_id).count
      
      template_stats.map do |template_id, count|
        template = CommunicationTemplate.find_by(id: template_id)
        next unless template
        
        template_comms = scope.where(template_id: template_id)
        
        {
          template_id: template_id,
          template_name: template.name,
          total_sent: count,
          delivered: template_comms.where(status: 'delivered').count,
          failed: template_comms.where(status: 'failed').count,
          open_rate: calculate_template_open_rate(template_comms),
          click_rate: calculate_template_click_rate(template_comms)
        }
      end.compact
    end
    
    # Get top performing communications
    def top_performing(limit: 10, metric: 'opens')
      case metric
      when 'opens'
        top_by_opens(limit)
      when 'clicks'
        top_by_clicks(limit)
      when 'engagement'
        top_by_engagement(limit)
      else
        []
      end
    end
    
    # Get failure analysis
    def failure_analysis(filters = {})
      scope = apply_filters(Communication.failed, filters)
      
      {
        total_failures: scope.count,
        by_channel: scope.group(:channel).count,
        by_provider: scope.group(:provider).count,
        common_errors: extract_common_errors(scope),
        failure_rate_by_hour: failure_rate_by_hour(scope)
      }
    end
    
    # Get scheduled communication statistics
    def scheduled_stats
      {
        total_scheduled: Communication.where(scheduled_status: 'scheduled').count,
        upcoming_24h: Communication.where(scheduled_status: 'scheduled')
                                   .where('scheduled_for > ? AND scheduled_for <= ?', Time.current, 24.hours.from_now)
                                   .count,
        overdue: Communication.where(scheduled_status: 'scheduled')
                              .where('scheduled_for < ?', Time.current)
                              .count,
        by_channel: Communication.where(scheduled_status: 'scheduled')
                                 .group(:channel)
                                 .count
      }
    end
    
    private
    
    # Apply filters to scope
    def apply_filters(scope, filters)
      scope = scope.where(channel: filters[:channel]) if filters[:channel]
      scope = scope.where(status: filters[:status]) if filters[:status]
      scope = scope.where(direction: filters[:direction]) if filters[:direction]
      scope = scope.where(communicable_type: filters[:communicable_type]) if filters[:communicable_type]
      
      if filters[:start_date]
        scope = scope.where('created_at >= ?', filters[:start_date])
      end
      
      if filters[:end_date]
        scope = scope.where('created_at <= ?', filters[:end_date])
      end
      
      if filters[:date_range]
        case filters[:date_range]
        when 'today'
          scope = scope.where('created_at >= ?', Time.current.beginning_of_day)
        when 'yesterday'
          scope = scope.where(created_at: 1.day.ago.beginning_of_day..1.day.ago.end_of_day)
        when 'last_7_days'
          scope = scope.where('created_at >= ?', 7.days.ago)
        when 'last_30_days'
          scope = scope.where('created_at >= ?', 30.days.ago)
        when 'this_month'
          scope = scope.where('created_at >= ?', Time.current.beginning_of_month)
        when 'last_month'
          scope = scope.where(created_at: 1.month.ago.beginning_of_month..1.month.ago.end_of_month)
        end
      end
      
      scope
    end
    
    # Count helpers
    def count_by_status(scope)
      scope.group(:status).count
    end
    
    def count_by_channel(scope)
      scope.group(:channel).count
    end
    
    def count_by_direction(scope)
      scope.group(:direction).count
    end
    
    # Rate calculations
    def calculate_delivery_rate(scope)
      total = scope.count
      return 0 if total.zero?
      
      delivered = scope.where(status: 'delivered').count
      (delivered.to_f / total * 100).round(2)
    end
    
    def calculate_failure_rate(scope)
      total = scope.count
      return 0 if total.zero?
      
      failed = scope.where(status: 'failed').count
      (failed.to_f / total * 100).round(2)
    end
    
    def calculate_template_open_rate(scope)
      return 0 unless scope.where(channel: 'email').any?
      
      total = scope.where(channel: 'email').count
      opened = scope.where(channel: 'email')
                    .joins(:communication_events)
                    .where(communication_events: { event_type: 'opened' })
                    .distinct
                    .count
      
      (opened.to_f / total * 100).round(2)
    end
    
    def calculate_template_click_rate(scope)
      return 0 unless scope.where(channel: 'email').any?
      
      total = scope.where(channel: 'email').count
      clicked = scope.where(channel: 'email')
                     .joins(:communication_events)
                     .where(communication_events: { event_type: 'clicked' })
                     .distinct
                     .count
      
      (clicked.to_f / total * 100).round(2)
    end
    
    # Time calculations
    def average_delivery_time(scope)
      delivered = scope.where.not(delivered_at: nil)
      return 0 if delivered.count.zero?
      
      total_time = delivered.sum do |comm|
        (comm.delivered_at - comm.created_at) / 60.0 # in minutes
      end
      
      (total_time / delivered.count).round(2)
    end
    
    def calculate_median(array)
      sorted = array.sort
      len = sorted.length
      (sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0
    end
    
    # Time grouping
    def group_by_hour(scope)
      scope.group_by_hour(:created_at).count
    end
    
    def group_by_day(scope)
      scope.group_by_day(:created_at).count
    end
    
    def group_by_week(scope)
      scope.group_by_week(:created_at).count
    end
    
    def group_by_month(scope)
      scope.group_by_month(:created_at).count
    end
    
    # Top performers
    def top_by_opens(limit)
      Communication.email
                   .joins(:communication_events)
                   .where(communication_events: { event_type: 'opened' })
                   .group('communications.id')
                   .order('COUNT(communication_events.id) DESC')
                   .limit(limit)
                   .pluck('communications.id', 'communications.subject', 'COUNT(communication_events.id)')
                   .map { |id, subject, count| { id: id, subject: subject, opens: count } }
    end
    
    def top_by_clicks(limit)
      Communication.email
                   .joins(:communication_events)
                   .where(communication_events: { event_type: 'clicked' })
                   .group('communications.id')
                   .order('COUNT(communication_events.id) DESC')
                   .limit(limit)
                   .pluck('communications.id', 'communications.subject', 'COUNT(communication_events.id)')
                   .map { |id, subject, count| { id: id, subject: subject, clicks: count } }
    end
    
    def top_by_engagement(limit)
      # Engagement = opens + clicks
      Communication.email
                   .joins(:communication_events)
                   .where(communication_events: { event_type: ['opened', 'clicked'] })
                   .group('communications.id')
                   .order('COUNT(communication_events.id) DESC')
                   .limit(limit)
                   .pluck('communications.id', 'communications.subject', 'COUNT(communication_events.id)')
                   .map { |id, subject, count| { id: id, subject: subject, engagement: count } }
    end
    
    # Error analysis
    def extract_common_errors(scope)
      scope.where.not(error_message: nil)
           .group(:error_message)
           .count
           .sort_by { |_, count| -count }
           .first(10)
           .to_h
    end
    
    def failure_rate_by_hour(scope)
      scope.group_by_hour(:failed_at).count
    end
  end
end
