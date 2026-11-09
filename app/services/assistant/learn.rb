# frozen_string_literal: true

module Assistant
  # What Quinn learned in a conversation, put where the team will see it
  # (E96): the buyer's answers and contact details on the lead, and their
  # question in the questions list. Shared by texts (AssistantReplyJob) and
  # the website chat (Assistant::WebChat).
  module Learn
    # What the buyer told the assistant, on the lead where the lead has a place
    # for it. Only blank fields are filled, so nothing a rep typed is overwritten.
    LEAD_FIELDS = { 'bedrooms' => :preferred_bedrooms, 'budget' => :budget_range,
                    'timeline' => :purchase_timeframe, 'home_type' => :preferred_home_type }.freeze

    EMAIL = /\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i
    # Names the system gave a lead before anyone knew it ("Text from (303) ...").
    PLACEHOLDER_NAME = /\Atext from\b|\Aunknown\z|\Anew lead\z/i

    # A person's name for notices to the team, or "the buyer at (303) ..."
    # while they are still named after their number.
    def self.display_name(record, fallback: 'A buyer')
      name = [record.try(:first_name), record.try(:last_name)].compact_blank.join(' ')
      return name if name.present? && !name.match?(PLACEHOLDER_NAME)

      phone = record.try(:phone).to_s.gsub(/\D/, '').last(10)
      phone.length == 10 ? "the buyer at (#{phone[0, 3]}) #{phone[3, 3]}-#{phone[6, 4]}" : fallback
    end

    module_function

    def apply!(conversation, result)
      conversation.merge_qualification!(result.qualification) if result.qualification.present?
      copy_fields(conversation.conversable, result.qualification)
      copy_contact(conversation.conversable, result.contact)
    end

    # Name, email and address the buyer typed, onto the lead's own fields, as
    # the lead form would. Fills what is blank (or a placeholder name); never
    # overwrites what a rep or a form already put there. Never the phone: a
    # number is used for texts only with the consent the form or chat asks for.
    def copy_contact(lead, contact)
      return if lead.nil? || contact.blank?

      changes = {}
      placeholder = lead.try(:first_name).to_s.match?(PLACEHOLDER_NAME) ||
                    [lead.try(:first_name), lead.try(:last_name)].join(' ').match?(PLACEHOLDER_NAME)
      %w[first_name last_name].each do |field|
        next unless contact[field].present? && lead.has_attribute?(field)

        changes[field] = contact[field].truncate(80) if lead[field].blank? || placeholder
      end
      email = contact['email'].to_s.downcase
      changes['email'] = email if email.match?(EMAIL) && lead.has_attribute?(:email) && lead.email.blank?
      %w[street city state zip].each do |field|
        changes[field] = contact[field].truncate(120) if contact[field].present? && lead.has_attribute?(field) && lead[field].blank?
      end
      return if changes.empty?

      lead.update!(changes)
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Learn] could not copy contact onto lead: #{e.message}")
    end

    def copy_fields(lead, fields)
      return if lead.nil? || fields.blank?

      changes = LEAD_FIELDS.each_with_object({}) do |(key, column), out|
        next unless fields[key].present? && lead.has_attribute?(column) && lead[column].blank?

        value = fields[key].to_s
        value = value[/\d+/]&.to_i if column == :preferred_bedrooms
        out[column] = value if value.present?
      end
      lead.update_columns(changes) if changes.any?
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Learn] could not copy onto lead: #{e.message}")
    end

    # Every question a buyer asks is kept (AssistantQuestion): the ones Quinn
    # could not answer are the dealer's list of answers to add, and all of them
    # show DealerTide what buyers ask.
    def record_question(conversation, result, reason, problem, communication_id: nil)
      return if result.question.blank?

      status = if reason || problem then 'handed_off'
               elsif result.question_answered then 'answered'
               else 'unanswered'
               end
      AssistantQuestion.create!(company_id: conversation.company_id, conversation_id: conversation.id,
                                communication_id: communication_id, question: result.question, status: status,
                                topic: result.question_topic, reply: problem ? nil : result.reply.to_s.truncate(600))
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Learn] could not record question: #{e.message}")
    end
  end
end
