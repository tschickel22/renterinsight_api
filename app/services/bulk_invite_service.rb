# frozen_string_literal: true

# Invites a pasted list of people into one company. Each person goes through
# InvitationService, which already sorts out the two cases: a new email gets a
# normal invite, and an email that signs in elsewhere gets a linked account.
# So nobody has to research who already has a login before inviting.
#
# match_roles gives someone with a login the role they hold in the company they
# sign in to. It is for linked accounts into an installer company, and reads
# another company's data, so only platform admins may ask for it, and only on an
# installer company (enforced by the controller).
class BulkInviteService
  MAX_PEOPLE = 50

  def initialize(invited_by:, company:, default_role: nil, match_roles: false)
    @invited_by = invited_by
    @company = company
    @default_role = default_role.presence
    @match_roles = match_roles
    @invitations = InvitationService.new(invited_by: invited_by, company: company)
  end

  # people: [{ email:, name: }]. One row back per distinct email, in order.
  def call(people)
    people.map { |p| [p[:email].to_s.strip.downcase, p[:name].to_s.strip] }
          .uniq(&:first)
          .map { |email, name| invite(email, name) }
  end

  private

  def invite(email, name)
    row = { email: email, name: name.presence, status: 'failed', role: nil, existing_login: false, error: nil }
    return row.merge(error: 'Not an email address') unless email.match?(URI::MailTo::EMAIL_REGEXP)
    return row.merge(status: 'already_here') if @company.users.where('LOWER(email) = ?', email).exists?

    login = User.sign_in_accounts.where('LOWER(email) = ?', email).where.not(company_id: @company.id).first
    role = role_for(login)
    return row.merge(existing_login: login.present?, error: 'Choose a role for this person') if role.blank?

    result = @invitations.create_invitation(
      invitation_type: 'company_user',
      email: email,
      recipient_name: name.presence || login&.read_attribute(:name),
      role: role,
      delivery_method: 'email'
    )
    return row.merge(existing_login: login.present?, error: result[:error]) unless result[:success]

    row.merge(status: 'invited', role: role, existing_login: login.present?)
  end

  def role_for(login)
    return @default_role unless @match_roles && login
    return @default_role if login.platform_admin? || login.super_admin?

    source = login.user_role_assignments.where(company_id: login.company_id).includes(:role).order(:id).first&.role
    return @default_role unless source

    source.company_id.nil? ? source.name : copy_into_company(source).name
  end

  # A custom role belongs to one company, so matching it means giving this
  # company its own copy with the same permissions. It stays separate from then
  # on: changing one company's role never changes the other's.
  def copy_into_company(source)
    existing = Role.find_by(company_id: @company.id, tier: source.tier, name: source.name)
    return existing if existing

    Role.transaction do
      copy = Role.create!(
        company_id: @company.id, tier: source.tier, name: source.name, description: source.description,
        color: source.color, department: source.department, is_system_role: false, active: true,
        key: "#{source.name.parameterize(separator: '_').first(80)}_#{SecureRandom.alphanumeric(6).downcase}"
      )
      now = Time.current
      rows = source.role_permissions.pluck(:resource_id, :action_id, :scope_id, :granted).map do |resource_id, action_id, scope_id, granted|
        { role_id: copy.id, resource_id: resource_id, action_id: action_id, scope_id: scope_id, granted: granted, created_at: now, updated_at: now }
      end
      RolePermission.insert_all(rows) if rows.any?
      copy
    end
  end
end
