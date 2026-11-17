# frozen_string_literal: true

# Photos, videos and files on a project, its phases and sub-tasks (E102).
#
# Everything lives in project_documents, whoever sent it:
#   * the dealer uploads on the project, a phase or a sub-task;
#   * a contractor's work log attachments and completion photos are recorded
#     here as well (record_contractor_files!), pointing at the same stored
#     file, so the dealer sees one set of pictures per job and can share them.
#
# Who sees a file is ProjectDocument#shown_to_client? / #shown_to_contractor?.
module ProjectMedia
  module_function

  VIDEO_MAX = 250.megabytes
  FILE_MAX = 25.megabytes

  def max_size_for(content_type)
    content_type.to_s.start_with?('video/') ? VIDEO_MAX : FILE_MAX
  end

  # Record a contractor's files on the project, under the task they worked.
  # files: hashes from the contractor upload ({url/s3_key, filename,
  # content_type, size}) or plain references/links (completion photos).
  # Never raises: a contractor's submission must not fail over this.
  def record_contractor_files!(assignment, files, work_log: nil)
    task = assignment&.assignable
    return [] unless task.is_a?(ProjectPhaseTask)

    phase = task.project_phase
    project = phase&.project
    return [] unless project

    Array(files).filter_map do |file|
      attrs = normalize_file(file)
      next unless attrs

      ref = PrivateFiles.normalize(attrs[:ref])
      next if ref.blank? || project.project_documents.where(file_url: ref).exists?
      # Only a file stored under this dealer's own folder: a reference sent by
      # the browser must not reach another company's files.
      next unless PrivateFiles.owned_by?(ref, project.company_id)

      key = PrivateFiles.locate(ref)&.last || attrs[:s3_key].to_s
      next if key.blank?

      content_type = attrs[:content_type].presence || guess_content_type(attrs[:filename] || key)
      project.project_documents.create!(
        company_id: project.company_id,
        documentable: task,
        source: 'contractor',
        vendor_id: assignment.contractor_id,
        contractor_assignment_id: assignment.id,
        title: attrs[:filename].presence || File.basename(key),
        category: ProjectDocument.category_for(content_type),
        file_url: ref,
        file_s3_key: key,
        file_name: attrs[:filename].presence || File.basename(key),
        file_size: attrs[:size],
        content_type: content_type,
        metadata: { 'work_log_id' => work_log&.id }.compact
      )
    end
  rescue StandardError => e
    Rails.logger.error("[ProjectMedia] could not record contractor files for assignment #{assignment&.id}: #{e.class}: #{e.message}")
    []
  end

  # The buyer's view: files they may see, keyed by phase id (nil = the whole
  # project). Only phases the buyer can see; a hidden sub-task's photos still
  # show under its phase, since sharing them is the point of ticking them.
  def client_files_by_phase(project, visible_phase_ids)
    visible = visible_phase_ids.to_set
    docs = project.project_documents.not_deleted.includes(:contractor, documentable: :project_phase)
                  .order(created_at: :desc).to_a
    docs.each_with_object(Hash.new { |h, k| h[k] = [] }) do |doc, acc|
      next unless doc.shown_to_client?(project_setting: project.share_media_with_client)

      phase_id = doc.phase&.id
      next if phase_id && !visible.include?(phase_id)
      next if doc.documentable_type.present? && phase_id.nil? # its phase or task is gone

      acc[phase_id] << client_json(doc, project)
    end
  end

  # What a buyer sees of one file. No dealer-internal names: a contractor
  # shows by their company name, the dealer by the dealership's.
  def client_json(doc, project)
    {
      id: doc.id,
      kind: kind(doc),
      url: PrivateFiles.url(doc.file_url),
      title: doc.title,
      description: doc.description,
      fileName: doc.file_name,
      contentType: doc.content_type,
      taskName: doc.phase_task&.name,
      from: doc.source == 'contractor' ? (doc.contractor&.name.presence || project.company&.name) : project.company&.name,
      createdAt: doc.created_at
    }
  end

  # A contractor's view of the dealer's files on one task: the task's own and
  # its phase's, as far as the dealer shares them. Their own uploads are
  # already in their work log.
  def contractor_files_for_task(task)
    phase = task.project_phase
    return [] unless phase

    scope = ProjectDocument.not_deleted.where(project_id: phase.project_id, source: 'dealer')
    docs = scope.where(documentable: task).or(scope.where(documentable: phase))
                .order(created_at: :desc)
    docs.select(&:shown_to_contractor?).map do |doc|
      {
        id: doc.id,
        kind: kind(doc),
        url: PrivateFiles.url(doc.file_url),
        title: doc.title,
        file_name: doc.file_name,
        content_type: doc.content_type,
        on: doc.documentable_type == 'ProjectPhase' ? 'phase' : 'task',
        from: phase.project.company&.name,
        created_at: doc.created_at
      }
    end
  end

  def kind(doc)
    return 'photo' if doc.image?
    return 'video' if doc.video?

    'file'
  end

  def normalize_file(file)
    case file
    when String
      { ref: file }
    when Hash, ActionController::Parameters
      h = file.respond_to?(:to_unsafe_h) ? file.to_unsafe_h : file
      h = h.stringify_keys
      ref = h['url'].presence || h['s3_key'].presence
      return nil unless ref

      ref = PrivateFiles.ref(h['s3_key']) if h['url'].blank? && h['s3_key'].present?
      { ref: ref, s3_key: h['s3_key'], filename: h['filename'] || h['file_name'],
        content_type: h['content_type'], size: h['size'] }
    end
  end

  def guess_content_type(name)
    Marcel::MimeType.for(name: name.to_s.split('?').first)
  rescue StandardError
    'application/octet-stream'
  end
end
