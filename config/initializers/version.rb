module Sure
  class << self
    def version
      Semver.new(semver)
    end

    def commit_sha
      if Rails.env.production?
        ENV["BUILD_COMMIT_SHA"]
      else
        `git rev-parse HEAD`.chomp
      end
    rescue Errno::ENOENT
      nil
    end

    # Repository that holds the source of the running build (AGPLv3 section 13).
    # Modified builds set SOURCE_REPOSITORY_URL to their own public repository.
    def source_repository_url
      ENV["SOURCE_REPOSITORY_URL"].presence || "https://github.com/we-promise/sure"
    end

    private
      def semver
        stripped_content = Rails.root.join(".sure-version").read.strip
        stripped_content.presence || "n/a: #{commit_sha}"
      rescue Errno::ENOENT
        "n/a: #{commit_sha || 'unknown'}"
      end
  end
end
