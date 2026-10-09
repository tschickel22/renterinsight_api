# frozen_string_literal: true

# Dealer agreement packages, for platform admins: the packages in the
# codebase, and installing one as a company's agreement template (what
# script/agreement_templates/*_packet.rb does from a console). The company
# name must match expect, as the scripts require, so a package cannot land
# on the wrong tenant: company ids differ per environment.
#
#   GET  /api/admin/agreement_packages
#   POST /api/admin/agreement_packages   { company_id, package, expect, apply? }   preview unless apply
class Api::Admin::AgreementPackagesController < ApplicationController
  before_action :require_platform_admin!

  def index
    render json: { packages: Agreements::PackageInstaller.available }
  end

  def create
    company = Company.find_by(id: params[:company_id])
    return render json: { error: 'No such company' }, status: :not_found unless company

    expect = params[:expect].to_s.strip
    unless expect.present? && company.name.downcase.include?(expect.downcase)
      return render json: { error: "Company #{company.id} is \"#{company.name}\", which does not match \"#{expect}\". Nothing changed." },
                    status: :unprocessable_entity
    end

    installer = Agreements::PackageInstaller.new(company, params[:package])
    return render json: { preview: installer.summary } unless ActiveModel::Type::Boolean.new.cast(params[:apply])

    template = installer.install!
    render json: { installed: installer.summary, template: { id: template.id, name: template.name } }, status: :created
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
