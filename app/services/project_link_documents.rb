# frozen_string_literal: true

# Photos and documents across a company link (E68 step 5d).
#
# Installer to dealer: photos are shared by default, other files when the
# installer marks them. Dealer to installer: only files the dealer marks,
# copied when the installer accepts the job (or straight away once it has).
# A shared file is copied into the other company's own storage, on the
# matching phase, so each company keeps and deletes its own copy. Unsharing
# or deleting the original removes the copy. A copy can't be shared on again.
#
# Every share is logged on the link.
class ProjectLinkDocuments
  LIVE = %w[accepted done].freeze

  # Is it shared when uploaded? Installer photos on a linked job, yes.
  def self.share_by_default?(doc)
    doc.category == 'photo' && ProjectLink.where(installer_project_id: doc.project_id, status: LIVE).exists?
  end

  # The other company on a project with a live link, and which side this
  # project is on, for the documents list ("Shared with ..."), or nil.
  # A dealer can mark files while the job waits for the installer; they
  # cross when it is accepted.
  def self.partner(project)
    pl = ProjectLink.where(status: [*LIVE, 'offered']).where('installer_project_id = :id OR dealer_project_id = :id', id: project.id)
                    .includes(:dealer_company, :installer_company).first
    return nil unless pl&.company_link&.active?

    if pl.installer_project_id == project.id
      { 'name' => pl.dealer_company.name, 'side' => 'installer' }
    else
      { 'name' => pl.installer_company.name, 'side' => 'dealer' }
    end
  end

  # Marks a document shared or not, and queues the copy or its removal.
  def self.set_shared!(doc, shared)
    raise ArgumentError, 'A file from the other company cannot be shared on' if copy?(doc)

    doc.update!(metadata: (doc.metadata || {}).merge('link_shared' => shared).deep_stringify_keys)
    ProjectLinkDocumentJob.perform_later(doc.id)
  end

  # The installer accepted: copy what the dealer had already marked.
  def self.share_marked_for(pl)
    ProjectDocument.not_deleted.where(project_id: pl.dealer_project_id).find_each do |doc|
      ProjectLinkDocumentJob.perform_later(doc.id) if doc.metadata&.dig('link_shared')
    end
  end

  def self.copy?(doc) = doc.metadata&.dig('link_copy_of').present?

  def initialize(doc)
    @doc = doc
  end

  # Brings the other side in line with the original: a copy when it is
  # shared and live, none when it is unshared or deleted.
  # Once the link ends or the job is taken back nothing more crosses, and
  # copies already made stay where they are.
  def sync!
    return if self.class.copy?(@doc) || target.nil?

    want = !@doc.is_deleted && @doc.metadata&.dig('link_shared')
    copy = existing_copy
    if want && !copy
      share!(*target)
    elsif !want && copy
      unshare!(copy)
    end
  end

  private

  def existing_copy
    id = @doc.metadata&.dig('link_copy_id')
    id && ProjectDocument.not_deleted.find_by(id: id)
  end

  # [project_link, the other project, its phase or nil] for this document.
  def target
    return @target if defined?(@target)

    @target = installer_side_target || dealer_side_target
  end

  def installer_side_target
    pl = live(ProjectLink.where(installer_project_id: @doc.project_id))
    return nil unless pl

    phase = mapped(pl, installer_phase_id: phase_id)&.dealer_phase if phase_id
    [pl, pl.dealer_project, phase || pl.dealer_phase]
  end

  def dealer_side_target
    ProjectLink.where(dealer_project_id: @doc.project_id, status: LIVE).find_each do |pl|
      next unless pl.company_link.active?

      if phase_id
        map = mapped(pl, dealer_phase_id: phase_id)
        return [pl, pl.installer_project, map.installer_phase] if map&.installer_phase
      elsif pl.whole_project?
        return [pl, pl.installer_project, nil]
      end
    end
    nil
  end

  def live(scope)
    pl = scope.where(status: LIVE).first
    pl if pl&.installer_project && pl.company_link.active?
  end

  def mapped(pl, **where) = pl.link_phases.includes(:dealer_phase, :installer_phase).find_by(**where)

  def phase_id
    @doc.documentable_id if @doc.documentable_type == 'ProjectPhase'
  end

  def share!(pl, project, phase)
    from = @doc.company_id == pl.installer_company_id ? pl.installer_company : pl.dealer_company
    stored = PrivateFiles.copy(@doc.file_url.presence || @doc.file_s3_key, folder: "projects/#{project.company_id}/#{project.id}/documents")
    copy = project.project_documents.create!(
      company_id: project.company_id, documentable: phase, title: @doc.title, description: @doc.description,
      category: @doc.category, file_url: stored[:ref], file_s3_key: stored[:key], file_name: @doc.file_name,
      file_size: @doc.file_size, content_type: @doc.content_type,
      metadata: { 'link_copy_of' => @doc.id, 'link_from' => from.name, 'project_link_id' => pl.id }
    )
    @doc.update_columns(metadata: (@doc.metadata || {}).merge('link_copy_id' => copy.id).deep_stringify_keys)
    pl.company_link.log!('document_shared', "#{from.name} shared #{@doc.category == 'photo' ? 'a photo' : 'a file'}: #{@doc.title}",
                         company: from, project_link: pl, data: { document_id: @doc.id, copy_id: copy.id })
  end

  def unshare!(copy)
    PrivateFiles.delete(copy.file_url.presence || copy.file_s3_key)
    copy.update!(is_deleted: true)
    @doc.update_columns(metadata: (@doc.metadata || {}).except('link_copy_id').deep_stringify_keys)
    pl = ProjectLink.find_by(id: copy.metadata&.dig('project_link_id'))
    return unless pl

    from = @doc.company_id == pl.installer_company_id ? pl.installer_company : pl.dealer_company
    pl.company_link.log!('document_unshared', "#{from.name} stopped sharing #{@doc.title}",
                         company: from, project_link: pl, data: { document_id: @doc.id, copy_id: copy.id })
  end
end
