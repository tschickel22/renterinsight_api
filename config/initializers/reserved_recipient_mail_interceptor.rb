# Mailers (notifications, reminders, portal mail) never deliver to a reserved
# address such as admin@acme.example.com. Demo companies are seeded entirely
# with those, so their users' task and reminder mail stays inside the platform.
# CommunicationService applies the same rule to everything it sends.
# See app/services/reserved_recipient.rb.
#
# Plain class here (not autoloaded) so code reloading in development cannot
# leave a stale interceptor registered. It looks ReservedRecipient up on each call.
class ReservedRecipientMailInterceptor
  def self.delivering_email(message)
    %i[to cc bcc].each do |field|
      list = Array(message.public_send(field))
      next if list.empty?

      kept = list.reject { |a| ReservedRecipient.block_email?(a) }
      message.public_send("#{field}=", kept.presence) if kept.size != list.size
    end

    return unless Array(message.to).empty? && Array(message.cc).empty? && Array(message.bcc).empty?

    Rails.logger.info "[ReservedRecipient] Not delivering mail #{message.subject.inspect}: every recipient is a reserved demo address"
    message.perform_deliveries = false
  end
end

ActiveSupport.on_load(:action_mailer) do
  ActionMailer::Base.register_interceptor(ReservedRecipientMailInterceptor)
end
