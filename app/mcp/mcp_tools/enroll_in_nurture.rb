# frozen_string_literal: true

module McpTools
  # Adds one person to an existing nurture sequence, the way a workflow's
  # "enroll in nurture" step does: sequence scoped to the company and active,
  # no second copy of the same sequence, and only one running sequence per
  # person (any other running one is paused, as the app does).
  #
  # Unlike a workflow or campaign there is no draft here: the first step
  # sends as soon as this runs, and a sent message cannot be recalled.
  class EnrollInNurture < Base
    tool_name 'enroll_in_nurture'
    title 'Add someone to a nurture sequence'
    description 'Add one lead, contact or account to an existing nurture sequence (ids from list_nurture_sequences ' \
                'and search). This STARTS IMMEDIATELY: the first email or text goes out now and cannot be recalled. ' \
                'Before calling, tell the user which sequence, which person, and what the first message is, and get ' \
                'a clear yes. Any other sequence that person is running is paused. One person per call; to add many ' \
                'people at once, the user should use the bulk enroll in DealerTide.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'lead:42, contact:7 or account:3' },
        sequence_id: { type: 'string', description: 'sequence:5 from list_nurture_sequences' }
      },
      required: %w[id sequence_id]
    )
    writes!(destructive: true, open_world: true)

    def self.perform(ctx, id:, sequence_id:)
      ctx.authorize!('crm', 'create')
      records = Records.new(ctx)
      type, person = records.find(id)
      raise UserError, 'Only leads, contacts and accounts can be added to a nurture sequence.' unless %w[lead contact account].include?(type)

      sequence = ctx.company.nurture_sequences.find_by(id: sequence_id.to_s.delete_prefix('sequence:').to_i)
      raise UserError, 'No nurture sequence with that id. See list_nurture_sequences.' unless sequence
      raise UserError, "#{sequence.name} is turned off, so nothing would send. Turn it on in DealerTide first." unless sequence.is_active

      mine = NurtureEnrollment.for_company(ctx.company.id).for_entity(person.class.name, person.id)
      if (existing = mine.where(nurture_sequence_id: sequence.id, status: %w[running idle paused]).first)
        raise UserError, "#{records.title(type, person)} is already in #{sequence.name} (#{existing.status}). " \
                         "#{existing.status == 'paused' ? 'Resume it on their record in DealerTide if it should continue.' : 'Nothing was changed.'}"
      end

      warnings = missing_contact_warnings(sequence, person)
      paused = mine.where(status: 'running').to_a
      enrollment = NurtureEnrollment.transaction do
        paused.each do |e|
          e.update!(status: 'paused')
          ctx.record_change(action: 'updated', record: e, before: { status: 'running' }, after: { status: 'paused' })
        end
        NurtureEnrollment.create!(enrollable: person, nurture_sequence: sequence, company: ctx.company, status: 'running')
      end
      ctx.record_change(action: 'created', record: enrollment, after: { status: 'running' })
      ProcessNurtureStepJob.perform_later(enrollment.id)

      Base::Result.new(payload: {
        enrolled: { person: records.title(type, person), sequence: sequence.name, enrollment_id: enrollment.id,
                    url: records.url(type, person) },
        paused_other_sequences: paused.map { |e| e.nurture_sequence&.name }.compact,
        warnings: warnings,
        note: 'The first step is sending now. To stop the rest of the sequence, pause it on their record in ' \
              'DealerTide, or undo this change under Settings, AI Apps (that pauses it; messages already sent stay sent).'
      }, count: 1)
    end

    def self.missing_contact_warnings(sequence, person)
      kinds = sequence.nurture_steps.map(&:step_type)
      warnings = []
      warnings << 'They have no email address, so the email steps will be skipped.' if kinds.include?('email') && person.try(:email).blank?
      warnings << 'They have no phone number, so the text steps will be skipped.' if kinds.include?('sms') && person.try(:phone).blank?
      warnings << 'They have opted out of email.' if kinds.include?('email') && person.try(:opt_out_email)
      warnings << 'They have opted out of texts.' if kinds.include?('sms') && person.try(:opt_out_sms)
      warnings
    end
  end
end
