
class Metis
  class File < Sequel::Model
    plugin :timestamps, update_on_create: true

    many_to_one :bucket
    many_to_one :folder
    many_to_one :data_block

    FILENAME_MATCH=/[^<>:;,?"*\|\/\x00-\x1f]+/x

    FILEPATH_MATCH=%r!
      \A
        (?<folders>(#{FILENAME_MATCH.source}/)*)

        (?<name>#{FILENAME_MATCH.source})
      \z
    !x

    def self.valid_file_path?(file_path)
      !!(file_path =~ FILEPATH_MATCH)
    end

    def self.valid_file_name?(file_name)
      !!(file_name =~ /\A#{FILENAME_MATCH.source}\z/)
    end

    def self.path_parts(file_path)
      FILEPATH_MATCH.match(file_path) do |match|
        return [
          # folder part, with no trailing slash
          match[:folders].empty? ? nil : match[:folders].sub(%r!/$!,''),

          # name part, with no trailing slash
          match[:name].sub(%r!/$!,'')
        ]
      end
    end

    def self.from_path(bucket, file_path)
      folder_path, file_name = path_parts(file_path)

      folder = folder_path && Metis::Folder.from_path(bucket, folder_path).last

      self.from_folder(bucket, folder, file_name)
    end

    def self.from_folder(bucket, folder, file_name)
      return self.where(
        bucket: bucket,
        folder_id: folder ? folder.id : nil,
        file_name: file_name
      ).first
    end

    def self.safe_file_name(file_name)
      file_name.unpack('H*').first
    end

    def self.unsafe_file_name(encoded_file_name)
      [encoded_file_name].pack('H*')
    end

    def self.md5(path)
      # use md5sum to avoid reading blob
      raise 'Invalid path for md5' unless Metis::File.valid_file_path?(path[1..-1])
      %x{ md5sum "#{path}" }.split.first
    end

    def self.upload_url(request, project_name, bucket_name, file_path)
      hmac_url(
        'POST',
        request.host,
        Metis::Server.route_path(
          request,
          :upload,
          project_name: project_name,
          bucket_name: bucket_name,
          file_path: file_path
        ),
        Metis.instance.config(:upload_expiration)
      )
    end

    def self.download_url(request, project_name, bucket_name, file_path)
      hmac_url(
        'GET',
        request.host,
        Metis::Server.route_path(
          request,
          :download,
          project_name: project_name,
          bucket_name: bucket_name,
          file_path: file_path
        ),
        Metis.instance.config(:download_expiration)
      )
    end

    def self.author(user)
      [ user.email, "#{user.first} #{user.last}" ].join('|')
    end

    def self.exists?(file_name, bucket, parent_folder)
      Metis::File.where(file_name: file_name, bucket: bucket, folder_id: parent_folder ? parent_folder.id : nil).count > 0
    end

    private

    def self.hmac_url(method, host, path, expiration=0)

      URI::HTTPS.build(
        Etna::Hmac.new(
          Metis.instance,
          method: method,
          host: host,
          path: path,
          expiration: (Time.now + expiration).iso8601,
          nonce: Metis.instance.sign.uid,
          id: :metis,
          headers: { }
        ).url_params
      )
    end

    public

    one_to_many :uploads

    def file_hash
      data_block.md5_hash
    end

    def read_only?
      read_only
    end

    def to_hash(request=nil)
      {
        file_name: file_name,
        project_name: project_name,
        bucket_name: bucket.name,
        file_path: file_path,
        updated_at: updated_at.iso8601,
        created_at: created_at.iso8601,
        author: author,
        file_hash: file_hash,
        archive_id: data_block.archive_id,
        read_only: read_only?,
        size: data_block.actual_size,
        download_url: request ? Metis::File.download_url(
          request,
          project_name,
          bucket.name,
          file_path
        ) : nil
      }
    end

    def file_path
      folder ? ::File.join(folder.folder_path, file_name) : file_name
    end

    def has_data?
      data_block.has_data?
    end

    def can_remove?
      !read_only?
    end

    def remove!
      delete
    end

    def protect!
      update(read_only: true)
    end

    def unprotect!
      update(read_only: false)
    end

    def rename!(new_folder, new_file_name)
      update(
        file_name: new_file_name,
        folder_id: new_folder ? new_folder.id : nil
      )
    end
  end
end
