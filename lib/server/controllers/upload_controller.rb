class UploadController < Metis::Controller
  def authorize
    require_params(:project_name, :bucket_name, :file_path)
    bucket = require_bucket
    folder_path, file_name = parse_path(@params[:file_path])
    folder = require_folder(bucket, folder_path)

    if folder && folder.read_only?
      raise Etna::Forbidden, 'Folder is read-only!'
    end

    file = Metis::File.from_folder(bucket, folder, file_name)

    raise Etna::Forbidden, 'File cannot be overwritten.' if file && file.read_only?

    # Create the upload
    upload = Metis::Upload.find_or_create(
      file_name: @params[:file_path],
      bucket: bucket,
      metis_uid: metis_uid,
      project_name: @params[:project_name]
    ) do |f|
      f.author = Metis::File.author(@user)
      f.file_size = 0
      f.current_byte_position = 0
      f.next_blob_size = -1
      f.next_blob_hash = ''
    end

    # Make a MAC url
    url = Metis::File.upload_url(
      @request,
      @params[:project_name],
      @params[:bucket_name],
      @params[:file_path]
    )

    success(url)
  end

  UPLOAD_ACTIONS=[ :start, :blob, :cancel, :reset ]

  # this endpoint handles multiple possible actions, allowing us to authorize
  # one path /upload and support several upload operations
  def upload
    require_param(:action)

    action = @params[:action].to_sym

    raise Etna::BadRequest, 'Incorrect upload action' unless UPLOAD_ACTIONS.include?(action)

    send :"upload_#{action}"
  end

  private

  # create a metadata entry in the database and also a file on
  # the file system with 0 bytes.
  def upload_start
    require_params(:file_size, :next_blob_size, :next_blob_hash)
    bucket = require_bucket

    upload = Metis::Upload.where(
      project_name: @params[:project_name],
      file_name: @params[:file_path],
      bucket: bucket,
      metis_uid: metis_uid,
    ).first

    raise Etna::BadRequest, 'No matching upload!' unless upload

    # the upload has been started already, report the current
    # position
    if upload.current_byte_position > 0
      return success_json(upload)
    end

    upload.update(
      file_size: @params[:file_size].to_i,
      next_blob_size: @params[:next_blob_size],
      next_blob_hash: @params[:next_blob_hash]
    )

    # Send upload initiated
    success_json(upload)
  end

  # Upload a chunk of the file.
  def upload_blob
    require_params(:blob_data, :next_blob_size, :next_blob_hash)
    bucket = require_bucket

    upload = Metis::Upload.where(
      project_name: @params[:project_name],
      file_name: @params[:file_path],
      bucket: bucket,
      metis_uid: metis_uid
    ).first

    raise Etna::BadRequest, 'Upload has not been started!' unless upload

    blob_path = @params[:blob_data][:tempfile].path

    raise Etna::BadRequest, 'Blob integrity failed' unless upload.blob_valid?(blob_path)

    upload.append_blob(blob_path)

    upload.update(
      next_blob_size: @params[:next_blob_size],
      next_blob_hash: @params[:next_blob_hash]
    )

    return complete_upload(upload) if upload.complete?

    return success_json(upload)
  end

  private

  def complete_upload(upload)
    folder_path, file_name = Metis::File.path_parts(upload.file_name)
    folder = require_folder(upload.bucket, folder_path)

    if folder && folder.read_only?
      raise Etna::Forbidden, 'Folder is read-only!'
    end

    file = Metis::File.from_folder(upload.bucket, folder, file_name)

    if file && file.read_only?
      raise Etna::Forbidden, 'Cannot overwrite existing file!'
    end

    upload.finish!

    return success_json(upload)
  ensure
    upload.delete_with_partial!
  end

  public

  def upload_cancel
    bucket = require_bucket

    upload = Metis::Upload.where(
      project_name: @params[:project_name],
      file_name: @params[:file_path],
      bucket: bucket,
      metis_uid: metis_uid
    ).first

    raise Etna::BadRequest, 'Upload has not been started!' unless upload

    # axe the upload data and record
    upload.delete_with_partial!

    return success('deleted')
  end

  private

  def metis_uid
    @request.cookies[Metis.instance.config(:metis_uid_name)]
  end
end
