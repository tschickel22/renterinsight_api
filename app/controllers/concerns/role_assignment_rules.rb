# frozen_string_literal: true

# Who may hand out which role. Inviting and creating a person both give someone
# a role, so both must apply the same limit: nobody grants a role at or above
# their own level, except the platform team, and except that a company admin may
# make another company admin (a dealer needs more than one).
module RoleAssignmentRules
  extend ActiveSupport::Concern

  COMPANY_ADMIN_LEVEL = 50

  private

  def can_assign_role?(target_role)
    return true if current_user.platform_admin? || current_user.super_admin?

    target_level = Api::Companies::UsersController::ROLE_HIERARCHY[target_role] || 0
    grantable_level?(role_level_of(current_user), target_level)
  end

  def grantable_level?(own_level, target_level)
    own_level > target_level || (own_level >= COMPANY_ADMIN_LEVEL && target_level == COMPANY_ADMIN_LEVEL)
  end

  def role_level_of(user)
    hierarchy = Api::Companies::UsersController::ROLE_HIERARCHY
    levels = [hierarchy[user.role] || 0]
    if @company&.use_rbac_system
      user.roles_for_company(@company.id).each do |role|
        levels << (hierarchy[role.key] || hierarchy[role.name] || 0)
      end
    end
    levels.max
  end
end
