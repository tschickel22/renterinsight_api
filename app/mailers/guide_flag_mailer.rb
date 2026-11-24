# frozen_string_literal: true

# Tells support when the help assistant has handed someone over (E118): what
# they asked, what they were told, and what the assistant looked at. The
# person was told someone will follow up, so this goes out as it happens.
# System-facing: platform brand, never the dealership's.
class GuideFlagMailer < ApplicationMailer
  KIND_LABELS = {
    'looks_wrong' => 'Something looks wrong', 'request' => 'Wants a change made',
    'feature_request' => 'Asked for a feature we do not have', 'not_expressible' => 'Report AI could not answer'
  }.freeze

  def flagged(flag_id)
    @flag = GuideFlag.find_by(id: flag_id)
    return if @flag.nil?

    @company = @flag.company
    @user = @flag.user
    @brand = Brand.current
    @label = KIND_LABELS[@flag.kind] || @flag.kind
    @admin_url = "#{@brand.app_url.to_s.chomp('/')}/admin/knowledge?tab=flags"

    mail(to: Guide::WeeklyDigest.recipient, from: default_from_address,
         subject: "Help: #{@label}, #{@company&.name || 'no company'}")
  end
end
